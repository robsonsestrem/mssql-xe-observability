/* 
 *
   SCRIPT DE ANÁLISE: dbo.history_plan_affecting_convert
   
   OBJETIVO : Investigar eventos de conversão implícita (plan_affecting_convert)
              coletados por Extended Events e carregados pela
              dbo.sp_load_plan_affecting_convert.

   AUTHOR: Robson Sestrem

   PROJETO: mssql-xe-observability
 *   
 */
USE DBA_PerformanceHub
GO

-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS DE ANÁLISE (ajuste aqui)
-- ============================================================================
DECLARE @DataInicial DATETIME = DATEADD(DAY, -30, GETDATE());  -- últimos 30 dias
DECLARE @DataFinal   DATETIME = GETDATE();                     -- até agora

/* ============================================================================
   SEÇÃO 1 — PANORAMA GERAL
   Volume diário de eventos, queries e expressões distintas.
   Útil para detectar picos (deploy, mudança de dados, horário de carga).
   ============================================================================ */
SELECT
    CONVERT(DATE, h.timestamp_xe)                                    AS dia
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT h.query_hash)                                 AS queries_distintas
  , COUNT_BIG(DISTINCT h.expression)                                 AS expressoes_distintas
  , COUNT_BIG(DISTINCT h.client_hostname)                            AS hosts_distintos
FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
GROUP BY CONVERT(DATE, h.timestamp_xe)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — DISTRIBUIÇÃO POR TIPO DE CONVERSÃO
   Lembrete: a sessão XE filtra convert_issue = 'Seek Plan' (2),
   então 'Cardinality Estimate' (1) NÃO é capturado por esta rotina.
   ============================================================================ */
SELECT
    h.convert_issue
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT h.query_hash)                                 AS queries_distintas
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
GROUP BY h.convert_issue
ORDER BY total_eventos DESC;

/* ============================================================================
   SEÇÃO 3 — RANKING DE EXPRESSÕES DE CONVERSÃO (diagnóstico principal)
   Agrupa pela expression exata. Quanto maior o volume e o nº de queries
   afetadas, maior a prioridade de correção.
   ============================================================================ */
SELECT TOP (50)
    h.expression
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT h.query_hash)                                 AS queries_afetadas
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
GROUP BY h.expression
ORDER BY total_eventos DESC;

/* ============================================================================
   SEÇÃO 4 — EXPRESSÕES DECOMPOSTAS: TIPO DESTINO, COLUNA CONVERTIDA E RISCO
   Faz o parsing de CONVERT_IMPLICIT(<tipo_destino>,[<origem>],<estilo>).
   A coluna dentro do CONVERT é a que está sendo convertida — é ela que
   impede o uso eficiente do índice (seek vira scan).
   SUPOSIÇÃO: expression no formato CONVERT_IMPLICIT(...). Expressões fora
   desse padrão são ignoradas nesta seção.
   ============================================================================ */
;WITH base AS
(
    SELECT
        h.expression
      , h.query_hash
      , h.timestamp_xe
      , CHARINDEX('CONVERT_IMPLICIT(', h.expression) AS pos_ini
    FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
    WHERE h.timestamp_xe >= @DataInicial
      AND h.timestamp_xe <  @DataFinal
      AND h.expression LIKE 'CONVERT_IMPLICIT(%'
)
, parsed AS
(
    SELECT
        b.expression
      , b.query_hash
      , b.timestamp_xe
      , LTRIM(RTRIM(SUBSTRING(b.expression, b.pos_ini + 17,
            CHARINDEX(',', b.expression, b.pos_ini + 17) - (b.pos_ini + 17)))) AS tipo_destino
      , LTRIM(RTRIM(SUBSTRING(b.expression,
            CHARINDEX(',', b.expression, b.pos_ini + 17) + 1,
            CHARINDEX(',', b.expression, CHARINDEX(',', b.expression, b.pos_ini + 17) + 1)
                - CHARINDEX(',', b.expression, b.pos_ini + 17) - 1))) AS origem
      , LTRIM(RTRIM(SUBSTRING(b.expression,
            CHARINDEX(',', b.expression, CHARINDEX(',', b.expression, b.pos_ini + 17) + 1) + 1,
            CHARINDEX(')', b.expression, CHARINDEX(',', b.expression, CHARINDEX(',', b.expression, b.pos_ini + 17) + 1))
                - CHARINDEX(',', b.expression, CHARINDEX(',', b.expression, b.pos_ini + 17) + 1) - 1))) AS estilo
    FROM base AS b
)
SELECT TOP (50)
    p.tipo_destino
  , p.origem
  , PARSENAME(REPLACE(REPLACE(p.origem, '[', ''), ']', ''), 1)      AS coluna_convertida
  , p.estilo
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT p.query_hash)                                 AS queries_afetadas
  , MIN(p.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(p.timestamp_xe)                                              AS ultima_ocorrencia
  , CASE
        WHEN p.tipo_destino IN ('int','bigint','smallint','tinyint','decimal','numeric','money','smallmoney','float','real')
            THEN 'ALTA'   -- conversão numérica sobre a coluna: bloqueia seek
        WHEN p.tipo_destino IN ('datetime','datetime2','date','smalldatetime','datetimeoffset','time')
            THEN 'MEDIA'  -- conversão de data/hora sobre a coluna
        WHEN p.tipo_destino IN ('nvarchar','varchar','nchar','char')
            THEN 'MEDIA'  -- possível mismatch de collation (varchar x nvarchar)
        ELSE 'BAIXA'
    END                                                              AS risco
FROM parsed AS p
GROUP BY
    p.tipo_destino
  , p.origem
  , PARSENAME(REPLACE(REPLACE(p.origem, '[', ''), ']', ''), 1)
  , p.estilo
  , CASE
        WHEN p.tipo_destino IN ('int','bigint','smallint','tinyint','decimal','numeric','money','smallmoney','float','real') THEN 'ALTA'
        WHEN p.tipo_destino IN ('datetime','datetime2','date','smalldatetime','datetimeoffset','time') THEN 'MEDIA'
        WHEN p.tipo_destino IN ('nvarchar','varchar','nchar','char') THEN 'MEDIA'
        ELSE 'BAIXA'
    END
ORDER BY total_eventos DESC;

/* ============================================================================
   SEÇÃO 5 — RANKING DE CONSULTAS (query_hash + sql_statement)
   Identifica as queries que mais geram conversões. sql_statement pode ser
   NULL se o plano saiu do cache — nesse caso, consulte sql_text na Seção 7.
   ============================================================================ */
SELECT TOP (50)
    h.query_hash
  , MAX(h.sql_statement)                                             AS sql_statement
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT h.expression)                                 AS conversoes_distintas
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.sql_statement IS NOT NULL
GROUP BY h.query_hash
ORDER BY total_eventos DESC;

/* ============================================================================
   SEÇÃO 6 — ORIGEM DOS EVENTOS (host, aplicação, usuário)
   Ajuda a rastrear qual aplicação/pod está gerando as conversões.
   ============================================================================ */
SELECT
    h.client_hostname
  , h.client_app_name
  , h.session_server_principal_name
  , h.username
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT h.query_hash)                                 AS queries_distintas
FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
GROUP BY
    h.client_hostname
  , h.client_app_name
  , h.session_server_principal_name
  , h.username
ORDER BY total_eventos DESC;

/* ============================================================================
   SEÇÃO 7 — CRUZAMENTO: TOP EXPRESSÕES x CONSULTA REPRESENTANTE
   Para cada expressão mais frequente, traz uma amostra do sql_statement
   (a ocorrência mais recente) — é o ponto de partida para a correção.
   ============================================================================ */
;WITH top_expressoes AS
(
    SELECT TOP (30)
        h.expression
      , COUNT_BIG(*) AS total_eventos
    FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
    WHERE h.timestamp_xe >= @DataInicial
      AND h.timestamp_xe <  @DataFinal
    GROUP BY h.expression
    ORDER BY total_eventos DESC
)
, amostra AS
(
    SELECT
        h.expression
      , h.sql_statement
      , h.timestamp_xe
      , ROW_NUMBER() OVER (PARTITION BY h.expression ORDER BY h.timestamp_xe DESC) AS rn
    FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
    WHERE h.sql_statement IS NOT NULL
)
SELECT
    te.expression
  , te.total_eventos
  , a.sql_statement
  , a.timestamp_xe AS ultima_ocorrencia
FROM top_expressoes AS te
LEFT JOIN amostra AS a
    ON a.expression = te.expression
   AND a.rn = 1
ORDER BY te.total_eventos DESC;

/* ============================================================================
   SEÇÃO 8 — DETALHE CRONOLÓGICO (eventos recentes para investigação manual)
   ============================================================================ */
SELECT TOP (100)
    h.timestamp_xe
  , h.database_name
  , h.convert_issue
  , h.expression
  , h.session_id
  , h.client_hostname
  , h.client_app_name
  , h.username
  , h.query_hash
  , h.query_plan_hash
  , h.sql_statement
  , h.sql_text
FROM dbo.history_plan_affecting_convert AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
ORDER BY h.timestamp_xe DESC;
