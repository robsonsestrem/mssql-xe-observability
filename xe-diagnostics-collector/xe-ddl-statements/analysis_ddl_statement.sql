/* 
 *
   OBJETIVO  : Investigar eventos de DDL (CREATE / ALTER / DROP de objetos)
               capturados pela sessão XE collect_ddl_statement e carregados
               pela dbo.sp_load_ddl_statement.
   PROJETO: mssql-xe-observability

   AUTHOR: Robson Sestrem
   
   ----------------------------------------------------------------------------
   1. MULTIPLICIDADE DE LINHAS: a proc faz CROSS APPLY em CADA frame do
      tsql_stack. Logo, um único evento DDL gera UMA LINHA POR NÍVEL DA
      PILHA de chamadas. Para contar "eventos reais", use frame_level = 0
      (instrução que disparou o DDL). frame_level > 0 = chamadores
      (procedures, triggers, ORM). As seções de contagem já aplicam isso;
      não remova o filtro sem reavaliar os totais.
 *
 */
USE DBA_PerformanceHub
GO

-- ============================================================================
-- SEÇÃO 0 — PARÂMETROS DE ANÁLISE (ajuste aqui)
-- ============================================================================
DECLARE @DataInicial DATETIME = DATEADD(DAY, -30, GETDATE());  -- últimos 30 dias
DECLARE @DataFinal   DATETIME = GETDATE();                     -- até agora
DECLARE @TopN        INT      = 50;                            -- tamanho dos rankings

/* ============================================================================
   SEÇÃO 1 — PANORAMA GERAL DIÁRIO
   Volume de mudanças por dia, com quebra por tipo de evento.
   Picos concentrados em horários curtos indicam deploy/migration scripts.
   ============================================================================ */
SELECT
    CONVERT(DATE, h.timestamp_xe)                                      AS dia
  , COUNT_BIG(*)                                                       AS mudancas_ddl
  , SUM(CASE WHEN h.event_name = 'object_created' THEN 1 ELSE 0 END)   AS criados
  , SUM(CASE WHEN h.event_name = 'object_altered' THEN 1 ELSE 0 END)   AS alterados
  , SUM(CASE WHEN h.event_name = 'object_deleted' THEN 1 ELSE 0 END)   AS removidos
  , COUNT_BIG(DISTINCT h.object_name + '|' + h.database_name)          AS objetos_distintos
  , COUNT_BIG(DISTINCT h.client_hostname)                              AS hosts_distintos
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0            -- uma linha por evento DDL real
GROUP BY CONVERT(DATE, h.timestamp_xe)
ORDER BY dia DESC

/* ============================================================================
   SEÇÃO 2 — DISTRIBUIÇÃO POR TIPO DE EVENTO
   Proporção de criações vs. alterações vs. remoções na janela analisada.
   ============================================================================ */
SELECT
    h.event_name
  , COUNT_BIG(*)                                                     AS total_eventos
  , COUNT_BIG(DISTINCT h.object_name)                                AS objetos_afetados
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0
GROUP BY h.event_name
ORDER BY total_eventos DESC

/* ============================================================================
   SEÇÃO 3 — RANKING DE OBJETOS MAIS MODIFICADOS
   Quais objetos sofreram mais mudanças e em quais bancos.
   Volume alto de ALTER em um objeto específico merece investigação
   (ex.: mudanças repetidas de schema por aplicação mal projetada).
   ============================================================================ */
SELECT TOP (@TopN)
    h.database_name
  , h.object_name
  , h.object_type
  , COUNT_BIG(*)                                                     AS total_mudancas
  , SUM(CASE WHEN h.event_name = 'object_created' THEN 1 ELSE 0 END) AS criados
  , SUM(CASE WHEN h.event_name = 'object_altered' THEN 1 ELSE 0 END) AS alterados
  , SUM(CASE WHEN h.event_name = 'object_deleted' THEN 1 ELSE 0 END) AS removidos
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0
GROUP BY
    h.database_name
  , h.object_name
  , h.object_type
ORDER BY total_mudancas DESC

/* ============================================================================
   SEÇÃO 4 — DISTRIBUIÇÃO POR TIPO DE OBJETO
   Visão macro: que tipo de objeto está sendo mais manipulado
   (TABLE, INDEX, VIEW, PROCEDURE, TRIGGER, etc.).
   ============================================================================ */
SELECT
    h.object_type
  , COUNT_BIG(*)                                                     AS total_mudancas
  , COUNT_BIG(DISTINCT h.object_name)                                AS objetos_distintos
  , SUM(CASE WHEN h.event_name = 'object_created' THEN 1 ELSE 0 END) AS criados
  , SUM(CASE WHEN h.event_name = 'object_deleted' THEN 1 ELSE 0 END) AS removidos
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0
  AND h.object_type IS NOT NULL
GROUP BY h.object_type
ORDER BY total_mudancas DESC

/* ============================================================================
   SEÇÃO 5 — ORIGEM DAS MUDANÇAS (quem está alterando)
   Login, host e aplicação que executaram os DDLs.
   Combine com a janela de tempo para correlacionar com deploys
   e com a investigação de acesso indevido.
   ============================================================================ */
SELECT
    h.session_server_principal_name
  , h.client_hostname
  , h.client_app_name
  , h.username
  , COUNT_BIG(*)                                                     AS total_ddls
  , COUNT_BIG(DISTINCT h.object_name)                                AS objetos_afetados
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0
GROUP BY
    h.session_server_principal_name
  , h.client_hostname
  , h.client_app_name
  , h.username
ORDER BY total_ddls DESC

/* ============================================================================
   SEÇÃO 6 — STATEMENTS DDL MAIS EXECUTADOS
   Os comandos que mais aparecem, agrupados pelo texto exato do frame.
   Ajuda a identificar migrations/scripts repetitivos (ex.: CREATE OR ALTER
   executado N vezes, DROP + CREATE em ciclo).
   LIMITAÇÃO: o agrupamento é por texto exato — variações de indentação
   ou parâmetros geram linhas separadas.
   ============================================================================ */
SELECT TOP (@TopN)
    LTRIM(RTRIM(h.sql_statement))                                    AS sql_statement
  , COUNT_BIG(*)                                                     AS execucoes
  , COUNT_BIG(DISTINCT h.object_name)                                AS objetos_afetados
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0
  AND h.sql_statement IS NOT NULL
GROUP BY LTRIM(RTRIM(h.sql_statement))
ORDER BY execucoes DESC

/* ============================================================================
   SEÇÃO 7 — PILHA DE CHAMADAS: quem disparou os DDLs
   Frames de nível > 0 = chamadores (procedures armazenadas, triggers,
   código do ORM). Combina o texto do chamador com a aplicação.
   É aqui que você descobre se o DDL foi manual, via migration ou
   obra de uma procedure/trigger automatizando mudanças de schema.
   ============================================================================ */
SELECT TOP (@TopN)
    h.client_app_name
  , h.frame_level
  , LTRIM(RTRIM(h.sql_statement))                                    AS chamador
  , COUNT_BIG(*)                                                     AS ocorrencias
  , MIN(h.timestamp_xe)                                              AS primeira_ocorrencia
  , MAX(h.timestamp_xe)                                              AS ultima_ocorrencia
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level > 0
  AND h.sql_statement IS NOT NULL
GROUP BY
    h.client_app_name
  , h.frame_level
  , LTRIM(RTRIM(h.sql_statement))
ORDER BY ocorrencias DESC

/* ============================================================================
   SEÇÃO 8 — DIAGNÓSTICO DA MULTIPLICIDADE DE LINHAS POR EVENTO
   Mostra eventos que geraram várias linhas no histórico (uma por frame
   do tsql_stack). Normalmente o evento tem N linhas = N níveis de pilha.
   Volumes altos aqui não significam mais DDLs — significam pilhas longas.
   ============================================================================ */
;WITH eventos AS
(
    SELECT
        h.timestamp_xe
      , h.session_id
      , h.event_name
      , h.database_name
      , h.object_name
      , COUNT_BIG(*)    AS linhas_no_historico
      , MAX(h.frame_level) AS max_frame_level
    FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
    WHERE h.timestamp_xe >= @DataInicial
      AND h.timestamp_xe <  @DataFinal
    GROUP BY
        h.timestamp_xe
      , h.session_id
      , h.event_name
      , h.database_name
      , h.object_name
)
SELECT TOP (@TopN)
    e.timestamp_xe
  , e.event_name
  , e.database_name
  , e.object_name
  , e.linhas_no_historico
  , e.max_frame_level
  , e.linhas_no_historico - 1 AS chamadores_capturados
FROM eventos AS e
ORDER BY e.linhas_no_historico DESC

/* ============================================================================
   SEÇÃO 9 — DETALHE CRONOLÓGICO (investigação manual)
   Últimos eventos DDL com o texto completo. O sql_statement é o comando
   específico do frame; o sql_text é o batch/comando completo que originou
   a mudança (use-o quando sql_statement for NULL).
   ============================================================================ */
SELECT TOP (100)
    h.timestamp_xe
  , h.event_name
  , h.database_name
  , h.object_name
  , h.object_type
  , h.index_id
  , h.session_id
  , h.session_server_principal_name
  , h.username
  , h.client_hostname
  , h.client_app_name
  , h.frame_level
  , h.sql_statement
  , h.sql_text
  , h.task_time                                                  -- microssegundos
FROM dbo.history_ddl_statement AS h WITH (NOLOCK)
WHERE h.timestamp_xe >= @DataInicial
  AND h.timestamp_xe <  @DataFinal
  AND h.frame_level = 0
ORDER BY h.timestamp_xe DESC


