/* ============================================================================
   SCRIPTS DE ANÁLISE: history_slow_query_statement + history_slow_query_batch_rpc
   ----------------------------------------------------------------------------
   OBJETIVO  : Investigar queries com duração >= 10s capturadas pelas sessões
               XE expensive_query_statement (sp_statement_completed) e
               expensive_query_batch_rpc (rpc_completed + sql_batch_completed).
   BANCO     : DBA_PerformanceHub
   COMPATIB. : SQL Server 2017+
   ----------------------------------------------------------------------------
   SUPOSIÇÕES E AVISOS CRÍTICOS:

   1. AS DUAS TABELAS SE SOBREPÕEM — NÃO SOME OS TOTAIS:
      Um EXEC de procedure lenta gera:
        - 1 evento em rpc_completed (nível externo, tabela batch_rpc)
        - N eventos em sp_statement_completed (um por statement interno)
      Somar as duas tabelas conta o mesmo trabalho mais de uma vez.
      A leitura correta é hierárquica: batch_rpc = nível externo,
      statement = nível interno. As seções abaixo respeitam essa hierarquia.

   2. object_name IDENTIFICA O TIPO DE EVENTO:
      Na tabela batch_rpc, object_name é 'rpc_completed' ou
      'sql_batch_completed' — é o nome do evento XE, não um objeto de banco.
      Use essa coluna para separar RPC de batch.

   3. result INDICA SUCESSO OU FALHA:
      Valores típicos: 'OK', 'Error', 'Abort'. Só existe para
      sql_batch_completed e rpc_completed. NULL para outros casos.
   ============================================================================ */

USE DBA_PerformanceHub
GO

-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS
-- ============================================================================
DECLARE @DataInicial DATETIME = DATEADD(DAY, -7, GETDATE());
DECLARE @DataFinal   DATETIME = GETDATE();
DECLARE @TopN        INT      = 50;

/* ============================================================================
   SEÇÃO 1 — PANORAMA GERAL DIÁRIO (batch/RPC — nível externo)
   Volume de operações lentas por dia, separando RPC de batch.
   Esta é a linha de base: quantas operações passaram de 10s.
   ============================================================================ */
SELECT
    CONVERT(DATE, b.Dt_Evento)                                         AS dia
  , COUNT_BIG(*)                                                       AS total_operacoes_lentas
  , SUM(CASE WHEN b.object_name = 'rpc_completed' THEN 1 ELSE 0 END)   AS rpc_completed
  , SUM(CASE WHEN b.object_name = 'sql_batch_completed' THEN 1 ELSE 0 END) AS sql_batch_completed
  , COUNT_BIG(DISTINCT b.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT b.client_app_name)                              AS apps_distintas
  , COUNT_BIG(DISTINCT b.database_name)                                AS bancos_distintos
  , CAST(MAX(b.duration) AS DECIMAL(18,2))                             AS maior_duracao_seg
  , CAST(AVG(b.duration) AS DECIMAL(18,2))                             AS media_duracao_seg
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
GROUP BY CONVERT(DATE, b.Dt_Evento)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — PANORAMA GERAL DIÁRIO (statement — nível interno)
   Volume de statements lentos dentro de procedures. Compare com a Seção 1:
   a diferença entre os dois mostra quantos statements internos cada
   operação externa gerou.
   ============================================================================ */
SELECT
    CONVERT(DATE, s.Dt_Evento)                                         AS dia
  , COUNT_BIG(*)                                                       AS total_statements_lentos
  , COUNT_BIG(DISTINCT s.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT s.client_app_name)                              AS apps_distintas
  , COUNT_BIG(DISTINCT s.database_name)                                AS bancos_distintos
  , CAST(MAX(s.duration) AS DECIMAL(18,2))                             AS maior_duracao_seg
  , CAST(AVG(s.duration) AS DECIMAL(18,2))                             AS media_duracao_seg
  , SUM(s.logical_reads)                                               AS total_leituras_logicas
FROM dbo.history_slow_query_statement AS s WITH (NOLOCK)
WHERE s.Dt_Evento >= @DataInicial
  AND s.Dt_Evento <  @DataFinal
GROUP BY CONVERT(DATE, s.Dt_Evento)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 3 — RANKING DE OPERAÇÕES MAIS CARAS (batch/RPC)
   Ordena por duração, CPU e leituras lógicas. Uma operação pode ser lenta
   por CPU (cálculo), por I/O (leituras) ou por espera (bloqueio).
   A razão entre cpu_time e duration separa os casos:
     - cpu_time ≈ duration  -> problema de CPU
     - cpu_time << duration -> espera (lock, I/O, rede)
   ============================================================================ */
SELECT TOP (@TopN)
    b.Dt_Evento
  , b.object_name                                                      AS tipo_evento
  , b.duration                                                         AS duracao_seg
  , b.cpu_time                                                         AS cpu_seg
  , CASE
        WHEN b.duration > 0
            THEN CAST(b.cpu_time * 100.0 / b.duration AS DECIMAL(6,2))
        ELSE NULL
    END                                                                AS pct_cpu_sobre_duracao
  , b.logical_reads
  , b.physical_reads
  , b.writes
  , b.row_count
  , b.database_name                                                    AS banco
  , b.session_id
  , b.client_app_name                                                  AS aplicacao
  , b.client_hostname                                                  AS host
  , b.session_server_principal_name                                    AS login_name
  , b.result
  , LEFT(COALESCE(b.batch_text, b.sql_text), 1000)                     AS comando_sql
  , CASE
        WHEN b.duration > 0 AND b.cpu_time * 100.0 / b.duration >= 80
            THEN 'CPU-BOUND: processamento intenso'
        WHEN b.duration > 0 AND b.cpu_time * 100.0 / b.duration < 30
            THEN 'ESPERA: bloqueio, I/O ou rede'
        ELSE 'MISTO: CPU e espera'
    END                                                                AS diagnostico
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
ORDER BY b.duration DESC;

/* ============================================================================
   SEÇÃO 4 — RANKING DE STATEMENTS MAIS CAROS (dentro de procedures)
   O detalhe interno. Mostra qual statement específico dentro da procedure
   consumiu o tempo. É aqui que se encontra a linha culpada.
   ============================================================================ */
SELECT TOP (@TopN)
    s.Dt_Evento
  , s.duration                                                         AS duracao_seg
  , s.cpu_time                                                         AS cpu_seg
  , CASE
        WHEN s.duration > 0
            THEN CAST(s.cpu_time * 100.0 / s.duration AS DECIMAL(6,2))
        ELSE NULL
    END                                                                AS pct_cpu_sobre_duracao
  , s.logical_reads
  , s.physical_reads
  , s.writes
  , s.row_count
  , s.database_name                                                    AS banco
  , s.session_id
  , s.client_app_name                                                  AS aplicacao
  , s.client_hostname                                                  AS host
  , s.session_server_principal_name                                    AS login_name
  , LEFT(s.sql_text, 1000)                                             AS comando_sql
  , CASE
        WHEN s.duration > 0 AND s.cpu_time * 100.0 / s.duration >= 80
            THEN 'CPU-BOUND: processamento intenso'
        WHEN s.duration > 0 AND s.cpu_time * 100.0 / s.duration < 30
            THEN 'ESPERA: bloqueio, I/O ou rede'
        ELSE 'MISTO: CPU e espera'
    END                                                                AS diagnostico
FROM dbo.history_slow_query_statement AS s WITH (NOLOCK)
WHERE s.Dt_Evento >= @DataInicial
  AND s.Dt_Evento <  @DataFinal
ORDER BY s.duration DESC;

/* ============================================================================
   SEÇÃO 5 — RANKING POR APLICAÇÃO E HOST
   Quem está gerando as operações lentas. Uma aplicação concentrando o
   problema indica padrão de acesso inadequado ou timeout mal configurado.
   ============================================================================ */
SELECT TOP (@TopN)
    b.client_app_name                                                  AS aplicacao
  , b.client_hostname                                                  AS host
  , b.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS operacoes_lentas
  , COUNT_BIG(DISTINCT b.session_id)                                   AS sessoes_distintas
  , SUM(CASE WHEN b.object_name = 'rpc_completed' THEN 1 ELSE 0 END)   AS rpc
  , SUM(CASE WHEN b.object_name = 'sql_batch_completed' THEN 1 ELSE 0 END) AS batch
  , CAST(MAX(b.duration) AS DECIMAL(18,2))                             AS maior_duracao_seg
  , CAST(AVG(b.duration) AS DECIMAL(18,2))                             AS media_duracao_seg
  , SUM(b.logical_reads)                                               AS total_leituras
  , MIN(b.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(b.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
GROUP BY
    b.client_app_name
  , b.client_hostname
  , b.database_name
ORDER BY operacoes_lentas DESC;

/* ============================================================================
   SEÇÃO 6 — PADRÕES DE COMANDO SQL MAIS LENTOS
   Agrupa pelo texto do comando. Identifica o código culpado.
   LIMITAÇÃO: agrupamento por texto exato; variações de parâmetro geram
   linhas separadas. Para normalizar, seria necessário query_hash — que
   não foi gravado na tabela.
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(COALESCE(b.batch_text, b.sql_text), 1000)                     AS comando_sql
  , b.object_name                                                      AS tipo_evento
  , COUNT_BIG(*)                                                       AS execucoes_lentas
  , COUNT_BIG(DISTINCT b.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT b.client_app_name)                              AS apps_distintas
  , CAST(MAX(b.duration) AS DECIMAL(18,2))                             AS maior_duracao_seg
  , CAST(AVG(b.duration) AS DECIMAL(18,2))                             AS media_duracao_seg
  , SUM(b.logical_reads)                                               AS total_leituras
  , MIN(b.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(b.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
  AND COALESCE(b.batch_text, b.sql_text) IS NOT NULL
GROUP BY
    LEFT(COALESCE(b.batch_text, b.sql_text), 1000)
  , b.object_name
ORDER BY execucoes_lentas DESC, maior_duracao_seg DESC;

/* ============================================================================
   SEÇÃO 7 — DISTRIBUIÇÃO POR FAIXA DE DURAÇÃO
   Separa o ruído do problema real. Uma query de 10-15s é diferente de
   uma de 5 minutos. A concentração revela se o problema é crônico
   (muitas queries no limite) ou pontual (poucas muito lentas).
   ============================================================================ */
;WITH faixas AS
(
    SELECT
        b.duration
      , b.session_id
      , b.client_app_name
      , CASE
            WHEN b.duration < 15   THEN '01 - 10s a 15s'
            WHEN b.duration < 30   THEN '02 - 15s a 30s'
            WHEN b.duration < 60   THEN '03 - 30s a 60s'
            WHEN b.duration < 120  THEN '04 - 1min a 2min'
            WHEN b.duration < 300  THEN '05 - 2min a 5min'
            WHEN b.duration < 600  THEN '06 - 5min a 10min'
            ELSE                        '07 - acima de 10min'
        END                                                            AS faixa_duracao
    FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
    WHERE b.Dt_Evento >= @DataInicial
      AND b.Dt_Evento <  @DataFinal
)
SELECT
    f.faixa_duracao
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS percentual
  , COUNT_BIG(DISTINCT f.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT f.client_app_name)                              AS apps_distintas
FROM faixas AS f
GROUP BY f.faixa_duracao
ORDER BY f.faixa_duracao;

/* ============================================================================
   SEÇÃO 8 — TIMELINE POR HORA (detecção de janelas críticas)
   Concentração horária indica job, ETL ou pico de acesso. Distribuição
   uniforme indica problema estrutural de performance.
   ============================================================================ */
SELECT
    CONVERT(DATE, b.Dt_Evento)                                         AS dia
  , DATEPART(HOUR, b.Dt_Evento)                                        AS hora
  , COUNT_BIG(*)                                                       AS operacoes_lentas
  , COUNT_BIG(DISTINCT b.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT b.client_app_name)                              AS apps_distintas
  , CAST(MAX(b.duration) AS DECIMAL(18,2))                             AS maior_duracao_seg
  , SUM(b.logical_reads)                                               AS total_leituras
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
GROUP BY
    CONVERT(DATE, b.Dt_Evento)
  , DATEPART(HOUR, b.Dt_Evento)
ORDER BY dia DESC, hora DESC;

/* ============================================================================
   SEÇÃO 9 — OPERAÇÕES COM FALHA (result <> 'OK')
   Filtra operações que terminaram com erro ou abort. Uma query lenta que
   falha é pior que uma lenta que completa: o cliente esperou e não
   recebeu resultado.
   ============================================================================ */
SELECT TOP (@TopN)
    b.Dt_Evento
  , b.object_name                                                      AS tipo_evento
  , b.result
  , b.duration                                                         AS duracao_seg
  , b.cpu_time                                                         AS cpu_seg
  , b.logical_reads
  , b.database_name                                                    AS banco
  , b.session_id
  , b.client_app_name                                                  AS aplicacao
  , b.client_hostname                                                  AS host
  , LEFT(COALESCE(b.batch_text, b.sql_text), 1000)                     AS comando_sql
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
  AND b.result IS NOT NULL
  AND b.result <> 'OK'
ORDER BY b.duration DESC;

/* ============================================================================
   SEÇÃO 10 — ANÁLISE DE I/O: LEITURAS LÓGICAS POR SEGUNDO
   Identifica queries que fazem varredura massiva. Uma query com 10 milhões
   de leituras lógicas em 10s está lendo ~1M páginas/s — sinal de scan
   sem índice. A razão leituras/segundo é o indicador de eficiência.
   ============================================================================ */
SELECT TOP (@TopN)
    b.Dt_Evento
  , b.object_name                                                      AS tipo_evento
  , b.duration                                                         AS duracao_seg
  , b.logical_reads
  , b.physical_reads
  , b.row_count
  , CASE
        WHEN b.duration > 0
            THEN CAST(b.logical_reads / b.duration AS DECIMAL(18,2))
        ELSE NULL
    END                                                                AS leituras_logicas_por_seg
  , CASE
        WHEN b.row_count > 0
            THEN CAST(b.logical_reads * 1.0 / b.row_count AS DECIMAL(18,2))
        ELSE NULL
    END                                                                AS leituras_por_linha
  , b.database_name                                                    AS banco
  , b.client_app_name                                                  AS aplicacao
  , LEFT(COALESCE(b.batch_text, b.sql_text), 800)                      AS comando_sql
  , CASE
        WHEN b.row_count > 0 AND b.logical_reads * 1.0 / b.row_count > 1000
            THEN 'SCAN PROVAVEL: muitas leituras por linha retornada'
        WHEN b.duration > 0 AND b.logical_reads / b.duration > 500000
            THEN 'I/O INTENSO: varredura massiva'
        ELSE 'Normal'
    END                                                                AS diagnostico
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
  AND b.logical_reads > 0
ORDER BY b.logical_reads DESC;

/* ============================================================================
   SEÇÃO 11 — SESSÕES REINCIDENTES
   Sessões que sofrem lentidão repetidamente. Um mesmo session_id com muitas
   operações lentas indica conexão problemática ou query específica.
   ATENÇÃO: session_id é reciclado pelo engine. Para análise de longo prazo,
   use client_hostname + client_app_name (Seção 5).
   ============================================================================ */
SELECT TOP (@TopN)
    b.session_id
  , b.client_app_name                                                  AS aplicacao
  , b.client_hostname                                                  AS host
  , b.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS operacoes_lentas
  , CAST(MAX(b.duration) AS DECIMAL(18,2))                             AS maior_duracao_seg
  , CAST(AVG(b.duration) AS DECIMAL(18,2))                             AS media_duracao_seg
  , SUM(b.logical_reads)                                               AS total_leituras
  , MIN(b.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(b.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_slow_query_batch_rpc AS b WITH (NOLOCK)
WHERE b.Dt_Evento >= @DataInicial
  AND b.Dt_Evento <  @DataFinal
GROUP BY
    b.session_id
  , b.client_app_name
  , b.client_hostname
  , b.database_name
HAVING COUNT_BIG(*) > 1
ORDER BY operacoes_lentas DESC;

/* ============================================================================
   SEÇÃO 12 — AGRUPAMENTO POR QUERY_HASH (via .xel)
   A análise que a tabela não permite: agrupa a mesma query entre execuções
   usando query_hash recuperado do arquivo. Identifica queries que são
   lentas de forma recorrente — não apenas uma vez.
   ATENÇÃO: leitura de arquivo é cara. Restrinja a janela de tempo.
   ============================================================================ */
;WITH eventos AS
(
    SELECT
        CAST(event_data AS XML).value('(action[@name="query_hash"]/value)[1]', 'varbinary(8)') AS query_hash_bin
      , CAST(event_data AS XML).value('(data[@name="duration"]/value)[1]', 'bigint')           AS duration_us
      , CAST(event_data AS XML).value('(data[@name="cpu_time"]/value)[1]', 'bigint')           AS cpu_time_us
      , CAST(event_data AS XML).value('(data[@name="logical_reads"]/value)[1]', 'bigint')      AS logical_reads
      , CAST(event_data AS XML).value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(128)') AS client_app_name
      , CAST(event_data AS XML).value('(action[@name="database_name"]/value)[1]', 'nvarchar(128)')   AS database_name
      , CAST(event_data AS XML).value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')  AS sql_text
      , timestamp_utc
    FROM sys.fn_xe_file_target_read_file(
            N'/var/opt/mssql/log_jobs/xe/expensive_query_batch_rpc*.xel',
            N'/var/opt/mssql/log_jobs/xe/expensive_query_batch_rpc*.xem',
            NULL, NULL)
    WHERE CAST(DATEADD(HOUR, DATEDIFF(HOUR, GETUTCDATE(), GETDATE()), CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) >= @DataInicial
      AND CAST(DATEADD(HOUR, DATEDIFF(HOUR, GETUTCDATE(), GETDATE()), CAST(timestamp_utc AS DATETIME2(3))) AS DATETIME) <  @DataFinal
)
SELECT TOP (@TopN)
    CONVERT(DECIMAL(38,0), CONVERT(BIGINT, e.query_hash_bin))          AS query_hash
  , COUNT_BIG(*)                                                       AS execucoes_lentas
  , COUNT_BIG(DISTINCT e.client_app_name)                              AS apps_distintas
  , MAX(e.database_name)                                               AS banco
  , CAST(MAX(e.duration_us) / 1000000.0 AS DECIMAL(18,3))              AS maior_duracao_seg
  , CAST(AVG(e.duration_us * 1.0) / 1000000.0 AS DECIMAL(18,3))        AS media_duracao_seg
  , CAST(SUM(e.cpu_time_us * 1.0) / 1000000.0 AS DECIMAL(18,3))        AS cpu_total_seg
  , SUM(e.logical_reads)                                               AS total_leituras
  , MAX(LEFT(e.sql_text, 1000))                                        AS comando_sql
  , MIN(e.timestamp_utc)                                               AS primeira_ocorrencia
  , MAX(e.timestamp_utc)                                               AS ultima_ocorrencia
FROM eventos AS e
WHERE e.query_hash_bin IS NOT NULL
GROUP BY CONVERT(DECIMAL(38,0), CONVERT(BIGINT, e.query_hash_bin))
ORDER BY execucoes_lentas DESC, maior_duracao_seg DESC;
