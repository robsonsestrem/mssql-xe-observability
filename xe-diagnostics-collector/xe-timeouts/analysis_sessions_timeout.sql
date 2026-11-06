/*
 *
   OBJETIVO: Investigar timeouts e conexões interrompidas capturados pela
             sessão XE monitoring_timeouts (evento sqlserver.attention) e
             carregados pela dbo.sp_load_sessions_timeout.

   PROJETO: mssql-xe-observability

   AUTHOR: Robson Sestrem
   ----------------------------------------------------------------------------
   SUPOSIÇÕES E AVISOS CRÍTICOS:

   1. duration ESTÁ EM MICROSSEGUNDOS:
      O evento attention traz duration em microssegundos. Para comparar com
      o timeout do driver (30s, 60s), divida por 1.000.000. As seções abaixo
      já fazem a conversão e expõem duration_segundos.

   2. attention NÃO DISTINGUE TIMEOUT DE CANCELAMENTO:
      Qualquer cancelamento do cliente gera attention: timeout do driver,
      botão Cancelar do SSMS, SqlCommand.Cancel(), queda de conexão.
      A tabela não separa os casos. A Seção 4 usa a distribuição de duration
      para inferir: timeouts se concentram perto do valor configurado no
      driver; cancelamentos manuais são aleatórios.
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
   Volume de timeouts, sessões distintas e duração média/máxima.
   Picos súbitos indicam degradação; volume constante indica problema crônico.
   ============================================================================ */
SELECT
    CONVERT(DATE, t.Dt_Evento)                                         AS dia
  , COUNT_BIG(*)                                                       AS timeouts
  , COUNT_BIG(DISTINCT t.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT t.client_hostname)                              AS hosts_distintos
  , COUNT_BIG(DISTINCT t.client_app_name)                              AS apps_distintas
  , COUNT_BIG(DISTINCT t.database_name)                                AS bancos_distintos
  , CAST(MAX(t.duration) / 1000000.0 AS DECIMAL(18,3))                 AS maior_duracao_seg
  , CAST(AVG(t.duration * 1.0) / 1000000.0 AS DECIMAL(18,3))           AS media_duracao_seg
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY CONVERT(DATE, t.Dt_Evento)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — DISTRIBUIÇÃO POR FAIXA DE DURAÇÃO
   A leitura mais reveladora. Timeouts de driver se concentram em valores
   próximos ao configurado (30s, 60s, 120s). Cancelamentos manuais e quedas
   de conexão se espalham por faixas aleatórias, inclusive muito curtas.
   Se a maioria está em 30-31s, é timeout de driver. Se está espalhada,
   é cancelamento ou problema de rede.
   ============================================================================ */
;WITH faixas AS
(
    SELECT
        t.duration
      , t.session_id
      , t.client_app_name
      , CASE
            WHEN t.duration IS NULL                              THEN '00 - Nao informado'
            WHEN t.duration < 1000000                            THEN '01 - menos de 1s'
            WHEN t.duration < 5000000                            THEN '02 - 1s a 5s'
            WHEN t.duration < 15000000                           THEN '03 - 5s a 15s'
            WHEN t.duration < 29000000                           THEN '04 - 15s a 29s'
            WHEN t.duration < 31000000                           THEN '05 - 29s a 31s (timeout 30s)'
            WHEN t.duration < 59000000                           THEN '06 - 31s a 59s'
            WHEN t.duration < 61000000                           THEN '07 - 59s a 61s (timeout 60s)'
            WHEN t.duration < 119000000                          THEN '08 - 61s a 119s'
            WHEN t.duration < 121000000                          THEN '09 - 119s a 121s (timeout 120s)'
            WHEN t.duration < 300000000                          THEN '10 - 121s a 300s'
            ELSE                                                      '11 - acima de 300s'
        END                                                            AS faixa_duracao
    FROM dbo.history_timeout AS t WITH (NOLOCK)
    WHERE t.Dt_Evento >= @DataInicial
      AND t.Dt_Evento <  @DataFinal
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
   SEÇÃO 3 — RANKING POR APLICAÇÃO E HOST
   Quem está sofrendo os timeouts. Uma aplicação concentrando o problema
   indica query lenta ou timeout mal configurado naquele cliente.
   ============================================================================ */
SELECT TOP (@TopN)
    t.client_app_name                                                  AS aplicacao
  , t.client_hostname                                                  AS host
  , t.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS timeouts
  , COUNT_BIG(DISTINCT t.session_id)                                   AS sessoes_distintas
  , CAST(MAX(t.duration) / 1000000.0 AS DECIMAL(18,3))                 AS maior_duracao_seg
  , CAST(AVG(t.duration * 1.0) / 1000000.0 AS DECIMAL(18,3))           AS media_duracao_seg
  , MIN(t.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(t.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY
    t.client_app_name
  , t.client_hostname
  , t.database_name
ORDER BY timeouts DESC;

/* ============================================================================
   SEÇÃO 4 — IDENTIFICAÇÃO DE TIMEOUT DE DRIVER vs CANCELAMENTO
   Classifica cada evento pela proximidade a um timeout típico de driver
   (30s, 60s, 120s, 300s). Eventos dentro de ±1s de um valor típico são
   provavelmente timeout de driver. Os demais são cancelamento manual,
   queda de conexão ou timeout customizado.
   SUPOSIÇÃO: os valores típicos (30/60/120/300s) são os padrões de mercado
   (ADO.NET, JDBC). Ajuste se sua aplicação usa outros valores.
   ============================================================================ */
SELECT
    CASE
        WHEN t.duration BETWEEN 29000000 AND 31000000
            THEN 'A - Timeout de driver (30s)'
        WHEN t.duration BETWEEN 59000000 AND 61000000
            THEN 'B - Timeout de driver (60s)'
        WHEN t.duration BETWEEN 119000000 AND 121000000
            THEN 'C - Timeout de driver (120s)'
        WHEN t.duration BETWEEN 299000000 AND 301000000
            THEN 'D - Timeout de driver (300s)'
        WHEN t.duration < 29000000
            THEN 'E - Cancelamento rapido / queda de conexao'
        ELSE 'F - Timeout customizado ou cancelamento tardio'
    END                                                                AS classificacao
  , COUNT_BIG(*)                                                       AS ocorrencias
  , CAST(COUNT_BIG(*) * 100.0 / SUM(COUNT_BIG(*)) OVER () AS DECIMAL(5,2)) AS percentual
  , COUNT_BIG(DISTINCT t.client_app_name)                              AS apps_distintas
  , COUNT_BIG(DISTINCT t.session_id)                                   AS sessoes_distintas
  , CAST(AVG(t.duration * 1.0) / 1000000.0 AS DECIMAL(18,3))           AS media_duracao_seg
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY
    CASE
        WHEN t.duration BETWEEN 29000000 AND 31000000 THEN 'A - Timeout de driver (30s)'
        WHEN t.duration BETWEEN 59000000 AND 61000000 THEN 'B - Timeout de driver (60s)'
        WHEN t.duration BETWEEN 119000000 AND 121000000 THEN 'C - Timeout de driver (120s)'
        WHEN t.duration BETWEEN 299000000 AND 301000000 THEN 'D - Timeout de driver (300s)'
        WHEN t.duration < 29000000 THEN 'E - Cancelamento rapido / queda de conexao'
        ELSE 'F - Timeout customizado ou cancelamento tardio'
    END
ORDER BY classificacao;

/* ============================================================================
   SEÇÃO 5 — TIMELINE POR HORA (detecção de janelas críticas)
   Concentração horária indica job, ETL ou pico de acesso. Distribuição
   uniforme indica problema estrutural de performance.
   ============================================================================ */
SELECT
    CONVERT(DATE, t.Dt_Evento)                                         AS dia
  , DATEPART(HOUR, t.Dt_Evento)                                        AS hora
  , COUNT_BIG(*)                                                       AS timeouts
  , COUNT_BIG(DISTINCT t.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT t.client_app_name)                              AS apps_distintas
  , CAST(MAX(t.duration) / 1000000.0 AS DECIMAL(18,3))                 AS maior_duracao_seg
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY
    CONVERT(DATE, t.Dt_Evento)
  , DATEPART(HOUR, t.Dt_Evento)
ORDER BY dia DESC, hora DESC;

/* ============================================================================
   SEÇÃO 6 — SESSÕES REINCIDENTES
   Sessões que sofrem timeout repetidamente. Um mesmo session_id com muitos
   timeouts indica query específica problemática ou conexão instável.
   ATENÇÃO: session_id é reciclado pelo engine. Para análise de longo prazo,
   agrupe por client_hostname + client_app_name (Seção 3).
   ============================================================================ */
SELECT TOP (@TopN)
    t.session_id
  , t.client_app_name                                                  AS aplicacao
  , t.client_hostname                                                  AS host
  , t.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS timeouts
  , CAST(MAX(t.duration) / 1000000.0 AS DECIMAL(18,3))                 AS maior_duracao_seg
  , CAST(AVG(t.duration * 1.0) / 1000000.0 AS DECIMAL(18,3))           AS media_duracao_seg
  , MIN(t.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(t.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY
    t.session_id
  , t.client_app_name
  , t.client_hostname
  , t.database_name
HAVING COUNT_BIG(*) > 1
ORDER BY timeouts DESC;

/* ============================================================================
   SEÇÃO 7 — DISTRIBUIÇÃO POR BANCO
   Onde os timeouts se concentram. Um banco com volume desproporcional
   indica problema de performance naquele banco específico.
   ============================================================================ */
SELECT
    t.database_name                                                    AS banco
  , COUNT_BIG(*)                                                       AS timeouts
  , COUNT_BIG(DISTINCT t.session_id)                                   AS sessoes_distintas
  , COUNT_BIG(DISTINCT t.client_app_name)                              AS apps_distintas
  , CAST(MAX(t.duration) / 1000000.0 AS DECIMAL(18,3))                 AS maior_duracao_seg
  , CAST(AVG(t.duration * 1.0) / 1000000.0 AS DECIMAL(18,3))           AS media_duracao_seg
  , MIN(t.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(t.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY t.database_name
ORDER BY timeouts DESC;

/* ============================================================================
   SEÇÃO 8 — ANÁLISE POR USUÁRIO NT
   Quem está sofrendo os timeouts, no nível de autenticação Windows.
   Útil quando a aplicação usa autenticação integrada e cada usuário
   tem um perfil de acesso distinto.
   ============================================================================ */
SELECT TOP (@TopN)
    t.nt_username                                                      AS usuario_nt
  , t.session_nt_username                                              AS usuario_sessao_nt
  , t.client_hostname                                                  AS host
  , t.client_app_name                                                  AS aplicacao
  , COUNT_BIG(*)                                                       AS timeouts
  , COUNT_BIG(DISTINCT t.session_id)                                   AS sessoes_distintas
  , CAST(MAX(t.duration) / 1000000.0 AS DECIMAL(18,3))                 AS maior_duracao_seg
  , MIN(t.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(t.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
GROUP BY
    t.nt_username
  , t.session_nt_username
  , t.client_hostname
  , t.client_app_name
ORDER BY timeouts DESC;

/* ============================================================================
   SEÇÃO 9 — DETECÇÃO DE SURTOS (rajadas de timeout)
   Identifica janelas de 1 minuto com volume anormal de timeouts. Surtos
   súbitos indicam bloqueio generalizado, CPU saturada ou falha de rede —
   não query individual lenta.
   ============================================================================ */
;WITH por_minuto AS
(
    SELECT
        DATEADD(MINUTE, DATEDIFF(MINUTE, 0, t.Dt_Evento), 0)           AS minuto
      , COUNT_BIG(*)                                                   AS timeouts
      , COUNT_BIG(DISTINCT t.session_id)                               AS sessoes_distintas
      , COUNT_BIG(DISTINCT t.client_app_name)                          AS apps_distintas
      , COUNT_BIG(DISTINCT t.database_name)                            AS bancos_distintos
    FROM dbo.history_timeout AS t WITH (NOLOCK)
    WHERE t.Dt_Evento >= @DataInicial
      AND t.Dt_Evento <  @DataFinal
    GROUP BY DATEADD(MINUTE, DATEDIFF(MINUTE, 0, t.Dt_Evento), 0)
)
, estatistica AS
(
    SELECT
        AVG(timeouts * 1.0)                                            AS media_timeouts
      , STDEV(timeouts * 1.0)                                          AS desvio_timeouts
    FROM por_minuto
)
SELECT TOP (@TopN)
    p.minuto
  , p.timeouts
  , p.sessoes_distintas
  , p.apps_distintas
  , p.bancos_distintos
  , CAST(e.media_timeouts AS DECIMAL(18,2))                            AS media_geral
  , CAST(e.desvio_timeouts AS DECIMAL(18,2))                           AS desvio_geral
  , CASE
        WHEN e.desvio_timeouts > 0
            THEN CAST((p.timeouts - e.media_timeouts) / e.desvio_timeouts AS DECIMAL(10,2))
        ELSE NULL
    END                                                                AS z_score
  , CASE
        WHEN e.desvio_timeouts > 0
         AND (p.timeouts - e.media_timeouts) / e.desvio_timeouts >= 3
            THEN 'SURTO CRITICO (3+ desvios)'
        WHEN e.desvio_timeouts > 0
         AND (p.timeouts - e.media_timeouts) / e.desvio_timeouts >= 2
            THEN 'SURTO (2+ desvios)'
        ELSE 'Normal'
    END                                                                AS diagnostico
FROM por_minuto AS p
CROSS JOIN estatistica AS e
ORDER BY p.timeouts DESC;

/* ============================================================================
   SEÇÃO 10 — DETALHE CRONOLÓGICO (investigação manual)
   Últimos eventos com todas as colunas relevantes.
   ============================================================================ */
SELECT TOP (200)
    t.Dt_Evento
  , t.session_id
  , t.duration
  , CAST(t.duration / 1000000.0 AS DECIMAL(18,3))                      AS duration_segundos
  , t.server_instance_name
  , t.database_name
  , t.nt_username
  , t.session_nt_username
  , t.client_hostname
  , t.client_app_name
  , CASE WHEN t.sql_text IS NULL THEN 'NULL (CAST falhou na carga)' ELSE 'SQL presente' END AS status_sql_text
FROM dbo.history_timeout AS t WITH (NOLOCK)
WHERE t.Dt_Evento >= @DataInicial
  AND t.Dt_Evento <  @DataFinal
ORDER BY t.Dt_Evento DESC;


