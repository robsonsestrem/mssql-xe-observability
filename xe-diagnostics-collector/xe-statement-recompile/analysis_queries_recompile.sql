/*
 *
   OBJETIVO: Investigar recompilações de statement capturadas pela sessão XE
             dark_queries_recompile (evento sqlserver.sql_statement_recompile)
             e carregadas pela dbo.sp_load_dark_queries_recompile.

   PROJETO: mssql-xe-observability

   AUTHOR: Robson Sestrem
   ----------------------------------------------------------------------------
   SUPOSIÇÕES E AVISOS CRÍTICOS:

   1. A SESSÃO CAPTURA DOIS UNIVERSOS DISTINTOS:
      O filtro é:
        recompile_cause = 'Option (recompile) requested'
        OR object_type IN ('ADHOC','PREPARED')
      Portanto a tabela contém:
        (a) recompilações por OPTION (RECOMPILE), em qualquer tipo de objeto
        (b) recompilações de QUALQUER causa em batches ADHOC ou PREPARED
      As seções abaixo separam os dois. Não trate o total como
      "recompilações por OPTION (RECOMPILE)" — seria falso.

   2. recompile_cause É GRAVADO COMO TEXTO:
      A carga usa (data[@name="recompile_cause"]/text)[1] como nvarchar(100).
      O XML do evento mapeia o enum para rótulo. Os valores possíveis
      (SQL Server 2017) são:
        1  Schema changed
        2  Statistics changed
        3  Deferred compile
        4  SET option changed
        5  Temporary table changed
        6  Remote rowset changed
        7  FOR BROWSE permission changed
        8  Query notification environment changed
        9  Partitioned view changed
        10 Cursor options changed
        11 OPTION (RECOMPILE) requested
        12 Parameterized plan flushed
        13 Test plan linearization
        14 Plan affecting database version changed
        15 Query Store plan forcing policy changed
        16 Query Store plan forcing failed
        17 Query Store missing the plan
      Se o seu build gravar o número em vez do rótulo, as seções abaixo
      tratam ambos os formatos.

   3. [offset] e offset_end DELIMITAM O STATEMENT:
      São posições em bytes no batch (sql_text). Permitem extrair o
      statement exato que recompilou, não o batch inteiro. A Seção 6
      usa isso.
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
   Volume de recompilações, comandos distintos e origem. Queda abrupta pode
   indicar sessão XE parada, não ausência de recompilação.
   ============================================================================ */
SELECT
    CONVERT(DATE, r.Dt_Evento)                                         AS dia
  , COUNT_BIG(*)                                                       AS recompilacoes
  , COUNT_BIG(DISTINCT r.recompile_cause)                              AS causas_distintas
  , COUNT_BIG(DISTINCT r.object_type)                                  AS tipos_objeto
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT r.client_app_name)                              AS apps_distintas
  , COUNT_BIG(DISTINCT r.database_name)                                AS bancos_afetados
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
GROUP BY CONVERT(DATE, r.Dt_Evento)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — DISTRIBUIÇÃO POR CAUSA DE RECOMPILAÇÃO
   O diagnóstico primário. Separa recompilações intencionais (OPTION
   RECOMPILE) das involuntárias (schema, estatística, temp table).
   Recompilação involuntária recorrente é problema; OPTION (RECOMPILE)
   é escolha de projeto.
   ============================================================================ */
SELECT
    r.recompile_cause                                                  AS valor_original
  , CASE
        WHEN r.recompile_cause LIKE '%Option (recompile)%'
          OR r.recompile_cause = '11'
            THEN '11 - OPTION (RECOMPILE) solicitado (intencional)'
        WHEN r.recompile_cause LIKE '%Schema changed%'
          OR r.recompile_cause = '1'
            THEN '01 - Schema changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Statistics changed%'
          OR r.recompile_cause = '2'
            THEN '02 - Statistics changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Deferred compile%'
          OR r.recompile_cause = '3'
            THEN '03 - Deferred compile (involuntaria)'
        WHEN r.recompile_cause LIKE '%SET option%'
          OR r.recompile_cause = '4'
            THEN '04 - SET option changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Temporary table%'
          OR r.recompile_cause = '5'
            THEN '05 - Temporary table changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Remote rowset%'
          OR r.recompile_cause = '6'
            THEN '06 - Remote rowset changed'
        WHEN r.recompile_cause LIKE '%BROWSE%'
          OR r.recompile_cause = '7'
            THEN '07 - FOR BROWSE permission changed'
        WHEN r.recompile_cause LIKE '%notification%'
          OR r.recompile_cause = '8'
            THEN '08 - Query notification environment changed'
        WHEN r.recompile_cause LIKE '%Partitioned view%'
          OR r.recompile_cause = '9'
            THEN '09 - Partitioned view changed'
        WHEN r.recompile_cause LIKE '%Cursor%'
          OR r.recompile_cause = '10'
            THEN '10 - Cursor options changed'
        WHEN r.recompile_cause LIKE '%Parameterized plan flushed%'
          OR r.recompile_cause = '12'
            THEN '12 - Parameterized plan flushed'
        WHEN r.recompile_cause LIKE '%Test plan linearization%'
          OR r.recompile_cause = '13'
            THEN '13 - Test plan linearization'
        WHEN r.recompile_cause LIKE '%database version%'
          OR r.recompile_cause = '14'
            THEN '14 - Plan affecting database version changed'
        WHEN r.recompile_cause LIKE '%forcing policy%'
          OR r.recompile_cause = '15'
            THEN '15 - Query Store plan forcing policy changed'
        WHEN r.recompile_cause LIKE '%forcing failed%'
          OR r.recompile_cause = '16'
            THEN '16 - Query Store plan forcing failed'
        WHEN r.recompile_cause LIKE '%missing the plan%'
          OR r.recompile_cause = '17'
            THEN '17 - Query Store missing the plan'
        ELSE COALESCE(r.recompile_cause, 'Nao informado')
    END                                                                AS causa_traduzida
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT r.sql_text)                                     AS comandos_distintos
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , MIN(r.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(r.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
GROUP BY
    r.recompile_cause
  , CASE
        WHEN r.recompile_cause LIKE '%Option (recompile)%' OR r.recompile_cause = '11' THEN '11 - OPTION (RECOMPILE) solicitado (intencional)'
        WHEN r.recompile_cause LIKE '%Schema changed%' OR r.recompile_cause = '1' THEN '01 - Schema changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Statistics changed%' OR r.recompile_cause = '2' THEN '02 - Statistics changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Deferred compile%' OR r.recompile_cause = '3' THEN '03 - Deferred compile (involuntaria)'
        WHEN r.recompile_cause LIKE '%SET option%' OR r.recompile_cause = '4' THEN '04 - SET option changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Temporary table%' OR r.recompile_cause = '5' THEN '05 - Temporary table changed (involuntaria)'
        WHEN r.recompile_cause LIKE '%Remote rowset%' OR r.recompile_cause = '6' THEN '06 - Remote rowset changed'
        WHEN r.recompile_cause LIKE '%BROWSE%' OR r.recompile_cause = '7' THEN '07 - FOR BROWSE permission changed'
        WHEN r.recompile_cause LIKE '%notification%' OR r.recompile_cause = '8' THEN '08 - Query notification environment changed'
        WHEN r.recompile_cause LIKE '%Partitioned view%' OR r.recompile_cause = '9' THEN '09 - Partitioned view changed'
        WHEN r.recompile_cause LIKE '%Cursor%' OR r.recompile_cause = '10' THEN '10 - Cursor options changed'
        WHEN r.recompile_cause LIKE '%Parameterized plan flushed%' OR r.recompile_cause = '12' THEN '12 - Parameterized plan flushed'
        WHEN r.recompile_cause LIKE '%Test plan linearization%' OR r.recompile_cause = '13' THEN '13 - Test plan linearization'
        WHEN r.recompile_cause LIKE '%database version%' OR r.recompile_cause = '14' THEN '14 - Plan affecting database version changed'
        WHEN r.recompile_cause LIKE '%forcing policy%' OR r.recompile_cause = '15' THEN '15 - Query Store plan forcing policy changed'
        WHEN r.recompile_cause LIKE '%forcing failed%' OR r.recompile_cause = '16' THEN '16 - Query Store plan forcing failed'
        WHEN r.recompile_cause LIKE '%missing the plan%' OR r.recompile_cause = '17' THEN '17 - Query Store missing the plan'
        ELSE COALESCE(r.recompile_cause, 'Nao informado')
    END
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 3 — SEPARAÇÃO DOS DOIS UNIVERSOS DA COLETA
   Quantifica quanto do histórico é OPTION (RECOMPILE) intencional versus
   recompilação involuntária em ADHOC/PREPARED. Esta é a leitura correta
   do que a sessão captura — sem ela, o total engana.
   ============================================================================ */
SELECT
    CASE
        WHEN r.recompile_cause LIKE '%Option (recompile)%' OR r.recompile_cause = '11'
            THEN 'A - OPTION (RECOMPILE) solicitado'
        WHEN r.object_type IN ('ADHOC', 'PREPARED')
            THEN 'B - Recompilacao involuntaria em ADHOC/PREPARED'
        ELSE 'C - Outros'
    END                                                                AS universo
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS percentual
  , COUNT_BIG(DISTINCT r.sql_text)                                     AS comandos_distintos
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
GROUP BY
    CASE
        WHEN r.recompile_cause LIKE '%Option (recompile)%' OR r.recompile_cause = '11'
            THEN 'A - OPTION (RECOMPILE) solicitado'
        WHEN r.object_type IN ('ADHOC', 'PREPARED')
            THEN 'B - Recompilacao involuntaria em ADHOC/PREPARED'
        ELSE 'C - Outros'
    END
ORDER BY universo;

/* ============================================================================
   SEÇÃO 4 — DISTRIBUIÇÃO POR TIPO DE OBJETO
   ADHOC, PREPARED, PROC, TRIGGER. Mostra onde a recompilação acontece.
   ADHOC alto indica aplicação enviando SQL sem parametrização.
   ============================================================================ */
SELECT
    r.object_type
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT r.sql_text)                                     AS comandos_distintos
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT r.client_app_name)                              AS apps_distintas
  , MIN(r.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(r.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
GROUP BY r.object_type
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 5 — RANKING DE COMANDOS MAIS RECOMPILADOS
   O diagnóstico acionável. Agrupa pelo texto do batch. Um comando
   recompilando milhares de vezes é o alvo direto da correção.
   LIMITAÇÃO: agrupamento por texto exato; variações de parâmetro geram
   linhas separadas. Para normalizar, use a Seção 6.
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(r.sql_text, 1000)                                             AS comando_sql
  , MAX(r.object_type)                                                 AS object_type
  , MAX(r.recompile_cause)                                             AS causa_principal
  , COUNT_BIG(*)                                                       AS recompilacoes
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT r.client_app_name)                              AS apps_distintas
  , MIN(r.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(r.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
  AND r.sql_text IS NOT NULL
GROUP BY LEFT(r.sql_text, 1000)
ORDER BY recompilacoes DESC;

/* ============================================================================
   SEÇÃO 6 — STATEMENT EXATO QUE RECOMPILOU (uso de offset/offset_end)
   As colunas offset e offset_end delimitam o statement dentro do batch.
   Aqui o statement é extraído com SUBSTRING, revelando exatamente qual
   linha recompilou — não o batch inteiro.
   SUPOSIÇÃO: offset e offset_end são posições em BYTES no batch.
   A divisão por 2 converte para caracteres em NVARCHAR. Se o seu build
   gravar em caracteres, remova a divisão.
   ============================================================================ */
SELECT TOP (@TopN)
    r.Dt_Evento
  , r.object_type
  , r.recompile_cause
  , r.[offset]
  , r.offset_end
  , CASE
        WHEN r.[offset] IS NOT NULL
         AND r.offset_end IS NOT NULL
         AND r.offset_end > r.[offset]
         AND r.sql_text IS NOT NULL
            THEN SUBSTRING(
                    r.sql_text
                  , (r.[offset] / 2) + 1
                  , ((r.offset_end - r.[offset]) / 2) + 1
                 )
        ELSE r.sql_text
    END                                                                AS statement_recompilado
  , LEFT(r.sql_text, 500)                                              AS batch_completo
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
ORDER BY r.Dt_Evento DESC;

/* ============================================================================
   SEÇÃO 7 — ORIGEM DAS RECOMPILAÇÕES (quem está provocando)
   Login, host e aplicação. Uma aplicação concentrando recompilações
   indica padrão de acesso inadequado — SQL ad-hoc sem parametrização,
   uso excessivo de OPTION (RECOMPILE) ou temp tables em loop.
   ============================================================================ */
SELECT TOP (@TopN)
    r.client_app_name                                                  AS aplicacao
  , r.client_hostname                                                  AS host
  , r.session_server_principal_name                                    AS login_name
  , r.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS recompilacoes
  , COUNT_BIG(DISTINCT r.sql_text)                                     AS comandos_distintos
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , MIN(r.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(r.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
GROUP BY
    r.client_app_name
  , r.client_hostname
  , r.session_server_principal_name
  , r.database_name
ORDER BY recompilacoes DESC;

/* ============================================================================
   SEÇÃO 8 — TIMELINE POR HORA (detecção de janelas de recompilação)
   Concentração horária indica job agendado, ETL ou relatório. Distribuição
   uniforme indica OLTP com recompilação contínua.
   ============================================================================ */
SELECT
    CONVERT(DATE, r.Dt_Evento)                                         AS dia
  , DATEPART(HOUR, r.Dt_Evento)                                        AS hora
  , COUNT_BIG(*)                                                       AS recompilacoes
  , COUNT_BIG(DISTINCT r.sql_text)                                     AS comandos_distintos
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
GROUP BY
    CONVERT(DATE, r.Dt_Evento)
  , DATEPART(HOUR, r.Dt_Evento)
ORDER BY dia DESC, hora DESC;

/* ============================================================================
   SEÇÃO 9 — RECOMPILAÇÕES INVOLUNTÁRIAS (o que realmente custa)
   Filtra apenas causas que NÃO são OPTION (RECOMPILE). Estas são as
   recompilações que o desenvolvedor não pediu — e que consomem CPU sem
   contrapartida. Priorize a correção por aqui.
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(r.sql_text, 1000)                                             AS comando_sql
  , r.recompile_cause                                                  AS causa
  , r.object_type
  , COUNT_BIG(*)                                                       AS recompilacoes
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT r.client_app_name)                              AS apps_distintas
  , MIN(r.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(r.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
  AND r.recompile_cause NOT LIKE '%Option (recompile)%'
  AND r.recompile_cause <> '11'
  AND r.sql_text IS NOT NULL
GROUP BY
    LEFT(r.sql_text, 1000)
  , r.recompile_cause
  , r.object_type
ORDER BY recompilacoes DESC;

/* ============================================================================
   SEÇÃO 10 — RECOMPILAÇÕES POR TEMP TABLE (causa 5)
   "Temporary table changed" é a causa mais comum de recompilação
   involuntária em procedures com temp tables. Ocorre quando o schema da
   temp table muda entre compilação e execução, ou quando o volume de
   linhas cruza o threshold de recompilação.
   Ação típica: OPTION (KEEPFIXED PLAN), ou reescrever para evitar
   temp table com schema variável.
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(r.sql_text, 1000)                                             AS comando_sql
  , COUNT_BIG(*)                                                       AS recompilacoes
  , COUNT_BIG(DISTINCT r.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT r.client_app_name)                              AS apps_distintas
  , MIN(r.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(r.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
  AND (r.recompile_cause LIKE '%Temporary table%' OR r.recompile_cause = '5')
  AND r.sql_text IS NOT NULL
GROUP BY LEFT(r.sql_text, 1000)
ORDER BY recompilacoes DESC;

/* ============================================================================
   SEÇÃO 11 — CORRELAÇÃO COM O PLANO EM CACHE
   Verifica se o comando recompilado ainda tem plano em cache e qual o
   custo acumulado. Sem query_hash na tabela, o elo é feito por
   sql_text comparado ao texto do cache (sys.dm_exec_sql_text).
   ATENÇÃO: comparação por texto é cara e imprecisa. Use TOP pequeno.
   sys.dm_exec_query_stats reflete apenas o cache atual.
   ============================================================================ */
;WITH comandos AS
(
    SELECT TOP (@TopN)
        LEFT(r.sql_text, 1000)                                         AS comando_sql
      , COUNT_BIG(*)                                                   AS recompilacoes
      , MAX(r.Dt_Evento)                                               AS ultima_ocorrencia
    FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
    WHERE r.Dt_Evento >= @DataInicial
      AND r.Dt_Evento <  @DataFinal
      AND r.sql_text IS NOT NULL
    GROUP BY LEFT(r.sql_text, 1000)
    ORDER BY COUNT_BIG(*) DESC
)
SELECT
    c.comando_sql
  , c.recompilacoes
  , c.ultima_ocorrencia
  , qs.execution_count                                                 AS execucoes_em_cache
  , qs.total_worker_time / 1000                                        AS cpu_total_ms
  , qs.total_elapsed_time / 1000                                       AS tempo_total_ms
  , qs.total_logical_reads                                            AS leituras_logicas
  , qs.plan_generation_num                                            AS geracoes_de_plano
  , CASE
        WHEN qs.sql_handle IS NULL THEN 'PLANO NAO ESTA MAIS EM CACHE'
        WHEN qs.plan_generation_num > 1 THEN 'PLANO RECOMPILADO NO CACHE'
        ELSE 'PLANO ESTAVEL'
    END                                                                AS diagnostico
FROM comandos AS c
OUTER APPLY
(
    SELECT TOP (1)
        q.sql_handle
      , q.execution_count
      , q.total_worker_time
      , q.total_elapsed_time
      , q.total_logical_reads
      , q.plan_generation_num
    FROM sys.dm_exec_query_stats AS q
    CROSS APPLY sys.dm_exec_sql_text(q.sql_handle) AS st
    WHERE LEFT(st.text, 1000) = c.comando_sql
    ORDER BY q.total_worker_time DESC
) AS qs
ORDER BY c.recompilacoes DESC;

/* ============================================================================
   SEÇÃO 12 — DETALHE CRONOLÓGICO (investigação manual)
   Últimos eventos com todas as colunas relevantes.
   ============================================================================ */
SELECT TOP (200)
    r.Dt_Evento
  , r.recompile_cause
  , r.object_type
  , r.database_name
  , r.session_id
  , r.session_server_principal_name
  , r.username
  , r.client_hostname
  , r.client_app_name
  , r.[offset]
  , r.offset_end
  , r.sql_text
FROM dbo.history_dark_queries_recompile AS r WITH (NOLOCK)
WHERE r.Dt_Evento >= @DataInicial
  AND r.Dt_Evento <  @DataFinal
ORDER BY r.Dt_Evento DESC;

