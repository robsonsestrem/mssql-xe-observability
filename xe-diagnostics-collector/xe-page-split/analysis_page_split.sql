/*
 *
    OBJETIVO: Investigar a atividade de escrita por índice capturada pela
              sessão XE monitor_page_splits_YOUR_DATABASE (evento
              sqlserver.transaction_log, operation = 11) e carregada pela
              sp_load_index_defrag_insert_page_splits_YOUR_DATABASE.
    
    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem
 *
 */
/* ============================================================================
   OBSERVACÕES
   ----------------------------------------------------------------------------
   1. AVISO — counted_splits NÃO É COMPARÁVEL ENTRE CARGAS:
      A procedure usa COUNT(*) OVER (PARTITION BY schema, tabela, índice,
      fill_factor) sobre o lote inteiro. Se a carga roda de hora em hora,
      o valor é por hora; se roda por dia, é por dia. Não há coluna de
      janela. Para comparar períodos, use as Seções 1 e 2 (contagem por
      timestamp_xe), não a coluna counted_splits.

   2. AVISO — fill_factor É LIDO NO MOMENTO DA CARGA:
      O valor vem de sys.indexes na hora do INSERT, não do momento do
      evento. Se o índice foi reconstruído entre o evento e a carga, o
      fill_factor registrado não corresponde ao que estava em uso.
   ============================================================================ */
USE DBA_PerformanceHub
GO

-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS
-- ============================================================================
DECLARE @DataInicial DATETIME2(3) = DATEADD(DAY, -7, SYSDATETIME());
DECLARE @DataFinal   DATETIME2(3) = SYSDATETIME();
DECLARE @TopN        INT          = 50;

/* ============================================================================
   SEÇÃO 1 — PANORAMA GERAL POR DIA
   Volume de modificações registradas por dia. Picos indicam carga em massa,
   ETL ou deploy. Queda abrupta pode indicar sessão XE parada, não ausência
   de atividade.
   ============================================================================ */
SELECT
    CONVERT(DATE, p.timestamp_xe)                                      AS dia
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.table_name)                                   AS tabelas_distintas
  , COUNT_BIG(DISTINCT p.index_name)                                   AS indices_distintos
  , COUNT_BIG(DISTINCT p.client_app_name)                              AS apps_distintas
  , COUNT_BIG(DISTINCT p.session_id)                                   AS sessoes_distintas
  , MIN(p.timestamp_xe)                                                AS primeiro_evento
  , MAX(p.timestamp_xe)                                                AS ultimo_evento
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
GROUP BY CONVERT(DATE, p.timestamp_xe)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — RANKING DE ÍNDICES POR ATIVIDADE DE ESCRITA
   O diagnóstico primário. Índices no topo são os que mais sofrem
   modificação — e, por consequência, os candidatos naturais a page split.
   Ordena por volume absoluto e por número de eventos distintos.
   ============================================================================ */
SELECT TOP (@TopN)
    p.schema_name
  , p.table_name
  , p.index_name
  , p.index_id
  , p.fill_factor
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.timestamp_xe)                                 AS eventos_distintos
  , COUNT_BIG(DISTINCT p.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT p.client_app_name)                              AS apps_distintas
  , MIN(p.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(p.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
GROUP BY
    p.schema_name
  , p.table_name
  , p.index_name
  , p.index_id
  , p.fill_factor
ORDER BY modificacoes DESC;

/* ============================================================================
   SEÇÃO 3 — ÍNDICES COM FILL FACTOR 100 E ALTA ATIVIDADE
   O cruzamento que realmente importa para page split. Fill factor 100
   (ou 0, equivalente) deixa a página cheia; qualquer INSERT no meio do
   índice força split. Índices nesta lista são os que mais se beneficiam
   de revisão de fill factor.
   SUPOSIÇÃO: fill_factor = 0 é tratado como 100 (comportamento do engine).
   ============================================================================ */
SELECT TOP (@TopN)
    p.schema_name
  , p.table_name
  , p.index_name
  , p.index_id
  , p.fill_factor
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT p.client_app_name)                              AS apps_distintas
  , MAX(p.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
  AND (p.fill_factor = 100 OR p.fill_factor = 0)
GROUP BY
    p.schema_name
  , p.table_name
  , p.index_name
  , p.index_id
  , p.fill_factor
ORDER BY modificacoes DESC;

/* ============================================================================
   SEÇÃO 4 — DISTRIBUIÇÃO POR TABELA
   Visão agregada por tabela, somando todos os índices. Uma tabela com
   muitas modificações distribuídas entre poucos índices indica escrita
   concentrada; distribuída entre muitos índices indica custo de
   manutenção de índice alto.
   ============================================================================ */
SELECT TOP (@TopN)
    p.schema_name
  , p.table_name
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.index_name)                                   AS indices_afetados
  , COUNT_BIG(DISTINCT p.session_id)                                   AS sessoes_distintas
  , MIN(p.fill_factor)                                                 AS menor_fill_factor
  , MAX(p.fill_factor)                                                 AS maior_fill_factor
  , MIN(p.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(p.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
GROUP BY
    p.schema_name
  , p.table_name
ORDER BY modificacoes DESC;

/* ============================================================================
   SEÇÃO 5 — ORIGEM DAS MODIFICAÇÕES (quem está escrevendo)
   Login, host e aplicação responsáveis pela atividade. Uma aplicação
   concentrando escritas em um índice específico é o alvo da otimização.
   ============================================================================ */
SELECT TOP (@TopN)
    p.client_app_name                                                  AS aplicacao
  , p.client_hostname                                                  AS host
  , p.session_server_principal_name                                    AS login_name
  , p.username
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.table_name)                                   AS tabelas_afetadas
  , COUNT_BIG(DISTINCT p.session_id)                                   AS sessoes_distintas
  , MIN(p.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(p.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
GROUP BY
    p.client_app_name
  , p.client_hostname
  , p.session_server_principal_name
  , p.username
ORDER BY modificacoes DESC;

/* ============================================================================
   SEÇÃO 6 — PADRÕES DE COMANDO SQL
   Agrupa pelo texto do comando que gerou a modificação. Identifica o
   código responsável pela escrita — e, por consequência, pelo page split.
   LIMITAÇÃO: agrupamento por texto exato; variações de parâmetro geram
   linhas separadas. sql_text pode ser NULL quando o plano saiu do cache.
   ============================================================================ */
SELECT TOP (@TopN)
    LEFT(p.sql_text, 1000)                                             AS comando_sql
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.table_name)                                   AS tabelas_afetadas
  , COUNT_BIG(DISTINCT p.index_name)                                   AS indices_afetados
  , MIN(p.timestamp_xe)                                                AS primeira_ocorrencia
  , MAX(p.timestamp_xe)                                                AS ultima_ocorrencia
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
  AND p.sql_text IS NOT NULL
GROUP BY LEFT(p.sql_text, 1000)
ORDER BY modificacoes DESC;

/* ============================================================================
   SEÇÃO 7 — TIMELINE POR HORA (detecção de janelas de carga)
   Distribuição horária das modificações. Concentração em horário
   específico indica job agendado ou ETL. Distribuição uniforme indica
   OLTP contínuo.
   ============================================================================ */
SELECT
    CONVERT(DATE, p.timestamp_xe)                                      AS dia
  , DATEPART(HOUR, p.timestamp_xe)                                     AS hora
  , COUNT_BIG(*)                                                       AS modificacoes
  , COUNT_BIG(DISTINCT p.table_name)                                   AS tabelas_distintas
  , COUNT_BIG(DISTINCT p.session_id)                                   AS sessoes_distintas
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
GROUP BY
    CONVERT(DATE, p.timestamp_xe)
  , DATEPART(HOUR, p.timestamp_xe)
ORDER BY dia DESC, hora DESC;

/* ============================================================================
   SEÇÃO 8 — EVOLUÇÃO TEMPORAL DE UM ÍNDICE ESPECÍFICO (drill-down)
   Dado schema/tabela/índice, mostra a evolução da atividade ao longo do
   tempo. Permite identificar se o volume cresceu, estabilizou ou parou.
   Substitua as variáveis abaixo.
   ============================================================================ */
DECLARE @SchemaAlvo NVARCHAR(128) = NULL;   -- ex.: 'dbo'
DECLARE @TabelaAlvo NVARCHAR(128) = NULL;   -- ex.: 'PSSOA'
DECLARE @IndiceAlvo NVARCHAR(128) = NULL;   -- ex.: 'PK_PSSOA'

SELECT
    CONVERT(DATE, p.timestamp_xe)                                      AS dia
  , DATEPART(HOUR, p.timestamp_xe)                                     AS hora
  , p.client_app_name                                                  AS aplicacao
  , p.session_id
  , COUNT_BIG(*)                                                       AS modificacoes
  , MIN(p.timestamp_xe)                                                AS primeiro_evento
  , MAX(p.timestamp_xe)                                                AS ultimo_evento
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
  AND (@SchemaAlvo IS NULL OR p.schema_name = @SchemaAlvo)
  AND (@TabelaAlvo IS NULL OR p.table_name = @TabelaAlvo)
  AND (@IndiceAlvo IS NULL OR p.index_name = @IndiceAlvo)
GROUP BY
    CONVERT(DATE, p.timestamp_xe)
  , DATEPART(HOUR, p.timestamp_xe)
  , p.client_app_name
  , p.session_id
ORDER BY dia DESC, hora DESC, modificacoes DESC;

/* ============================================================================
   SEÇÃO 9 — DETALHE CRONOLÓGICO (investigação manual)
   Últimos eventos com todas as colunas relevantes.
   ============================================================================ */
SELECT TOP (200)
    p.timestamp_xe
  , p.schema_name
  , p.table_name
  , p.index_name
  , p.index_id
  , p.fill_factor
  , p.alloc_unit_id
  , p.database_name
  , p.session_id
  , p.session_server_principal_name
  , p.username
  , p.client_hostname
  , p.client_app_name
  , p.sql_text
FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
WHERE p.timestamp_xe >= @DataInicial
  AND p.timestamp_xe <  @DataFinal
ORDER BY p.timestamp_xe DESC;

/* ============================================================================
   SEÇÃO 10 — CRUZAMENTO COM O ESTADO ATUAL DO ÍNDICE (diagnóstico real)
   Compara o que está registrado no histórico com o que existe hoje em
   sys.indexes e sys.dm_db_index_physical_stats. Aqui você vê:
     - se o índice ainda existe
     - o fill factor ATUAL versus o registrado no evento
     - a fragmentação real medida agora
   Esta é a seção que fecha o diagnóstico: atividade alta + fill factor 100
   + fragmentação alta = candidato direto a revisão.
   SUPOSIÇÃO: substitua YOUR_DATABASE pelo nome real do banco monitorado.
   ATENÇÃO: sys.dm_db_index_physical_stats é caro. Use SAMPLED, não DETAILED,
   e rode fora de horário de pico.
   ============================================================================ */
;WITH atividade AS
(
    SELECT
        p.schema_name
      , p.table_name
      , p.index_name
      , p.index_id
      , MAX(p.fill_factor)                                             AS fill_factor_registrado
      , COUNT_BIG(*)                                                   AS modificacoes
      , MAX(p.timestamp_xe)                                            AS ultima_ocorrencia
    FROM dbo.index_defrag_page_splits_YOUR_DATABASE AS p WITH (NOLOCK)
    WHERE p.timestamp_xe >= @DataInicial
      AND p.timestamp_xe <  @DataFinal
    GROUP BY
        p.schema_name
      , p.table_name
      , p.index_name
      , p.index_id
)
SELECT TOP (@TopN)
    a.schema_name
  , a.table_name
  , a.index_name
  , a.index_id
  , a.modificacoes
  , a.fill_factor_registrado
  , i.fill_factor                                                    AS fill_factor_atual
  , ps.avg_fragmentation_in_percent                                  AS fragmentacao_pct
  , ps.page_count                                                    AS paginas
  , ps.avg_page_space_used_in_percent                                AS ocupacao_pct
  , a.ultima_ocorrencia
  , CASE
        WHEN i.object_id IS NULL
            THEN 'INDICE NAO EXISTE MAIS'
        WHEN ps.avg_fragmentation_in_percent >= 30
             AND (i.fill_factor = 100 OR i.fill_factor = 0)
            THEN 'CRITICO: fragmentacao alta com fill factor 100'
        WHEN ps.avg_fragmentation_in_percent >= 30
            THEN 'ATENCAO: fragmentacao alta'
        WHEN (i.fill_factor = 100 OR i.fill_factor = 0)
             AND a.modificacoes > 1000
            THEN 'ATENCAO: fill factor 100 com escrita intensa'
        ELSE 'OK'
    END                                                                AS diagnostico
FROM atividade AS a
LEFT JOIN YOUR_DATABASE.sys.indexes AS i WITH (NOLOCK)
    ON i.name = a.index_name
LEFT JOIN YOUR_DATABASE.sys.tables AS t WITH (NOLOCK)
    ON t.object_id = i.object_id
   AND t.name = a.table_name
OUTER APPLY sys.dm_db_index_physical_stats(
        DB_ID(N'YOUR_DATABASE')
      , i.object_id
      , i.index_id
      , NULL
      , 'SAMPLED'
    ) AS ps
WHERE i.object_id IS NOT NULL
   OR ps.object_id IS NOT NULL
ORDER BY a.modificacoes DESC;
