/*
 *
    OBJETIVO: Investigar erros capturados pela sessão XE system_error_collection
              (evento sqlserver.error_reported) e carregados pela
              dbo.sp_load_database_error.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem
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
   Volume de erros por dia, com quebra por faixa de severidade.
   Picos súbitos indicam incidente; volume constante indica problema crônico.
   ============================================================================ */
SELECT
    CONVERT(DATE, e.Dt_Evento)                                         AS dia
  , COUNT_BIG(*)                                                       AS total_erros
  , SUM(CASE WHEN e.severity BETWEEN 17 AND 19 THEN 1 ELSE 0 END)      AS sev_17_a_19
  , SUM(CASE WHEN e.severity BETWEEN 20 AND 24 THEN 1 ELSE 0 END)      AS sev_20_a_24
  , SUM(CASE WHEN e.severity >= 25 THEN 1 ELSE 0 END)                  AS sev_25_mais
  , COUNT_BIG(DISTINCT e.error_number)                                 AS erros_distintos
  , COUNT_BIG(DISTINCT e.database_name)                                AS bancos_afetados
  , COUNT_BIG(DISTINCT e.client_hostname)                              AS hosts_distintos
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
GROUP BY CONVERT(DATE, e.Dt_Evento)
ORDER BY dia DESC;

/* ============================================================================
   SEÇÃO 2 — RANKING DE ERROS POR NÚMERO
   O diagnóstico primário. Agrupa por error_number e mostra severidade,
   volume e texto representativo. Erros recorrentes aqui são a lista de
   trabalho do DBA.
   ============================================================================ */
SELECT TOP (@TopN)
    e.error_number
  , MAX(e.severity)                                                    AS severidade_max
  , MIN(e.severity)                                                    AS severidade_min
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT e.database_name)                                AS bancos_afetados
  , COUNT_BIG(DISTINCT e.client_app_name)                              AS apps_afetadas
  , COUNT_BIG(DISTINCT e.username)                                     AS logins_distintos
  , MIN(e.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(e.Dt_Evento)                                                   AS ultima_ocorrencia
  , MAX(LEFT(e.message, 500))                                          AS mensagem_representativa
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
GROUP BY e.error_number
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 3 — DISTRIBUIÇÃO POR SEVERIDADE
   Traduz o número em impacto operacional. Severidade 17-19 é pressão de
   recurso (ação do DBA); 20-24 é risco de estabilidade ou corrupção.
   ============================================================================ */
SELECT
    e.severity
  , CASE
        WHEN e.severity = 17 THEN '17 - Recurso configuravel esgotado (memoria, locks, disco)'
        WHEN e.severity = 18 THEN '18 - Falha interna nao fatal do engine'
        WHEN e.severity = 19 THEN '19 - Limite nao configuravel excedido'
        WHEN e.severity = 20 THEN '20 - Erro fatal no processo atual'
        WHEN e.severity = 21 THEN '21 - Erro fatal em todos os processos do banco'
        WHEN e.severity = 22 THEN '22 - Suspeita de corrupcao de tabela/indice'
        WHEN e.severity = 23 THEN '23 - Suspeita de corrupcao do banco'
        WHEN e.severity = 24 THEN '24 - Erro de hardware / armazenamento'
        WHEN e.severity >= 25 THEN '25+ - Erro fatal de sistema'
        ELSE 'Outro'
    END                                                                AS descricao_severidade
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT e.error_number)                                 AS erros_distintos
  , COUNT_BIG(DISTINCT e.database_name)                                AS bancos_afetados
  , MIN(e.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(e.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
GROUP BY
    e.severity
  , CASE
        WHEN e.severity = 17 THEN '17 - Recurso configuravel esgotado (memoria, locks, disco)'
        WHEN e.severity = 18 THEN '18 - Falha interna nao fatal do engine'
        WHEN e.severity = 19 THEN '19 - Limite nao configuravel excedido'
        WHEN e.severity = 20 THEN '20 - Erro fatal no processo atual'
        WHEN e.severity = 21 THEN '21 - Erro fatal em todos os processos do banco'
        WHEN e.severity = 22 THEN '22 - Suspeita de corrupcao de tabela/indice'
        WHEN e.severity = 23 THEN '23 - Suspeita de corrupcao do banco'
        WHEN e.severity = 24 THEN '24 - Erro de hardware / armazenamento'
        WHEN e.severity >= 25 THEN '25+ - Erro fatal de sistema'
        ELSE 'Outro'
    END
ORDER BY e.severity;

/* ============================================================================
   SEÇÃO 4 — ERROS POR BANCO E POR APLICAÇÃO
   Onde o problema se concentra. Um banco com volume desproporcional indica
   problema de configuração ou de carga de trabalho daquele banco.
   ============================================================================ */
SELECT TOP (@TopN)
    e.database_name                                                    AS banco
  , e.client_app_name                                                  AS aplicacao
  , e.client_hostname                                                  AS host
  , COUNT_BIG(*)                                                       AS total_erros
  , COUNT_BIG(DISTINCT e.error_number)                                 AS erros_distintos
  , MAX(e.severity)                                                    AS maior_severidade
  , MIN(e.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(e.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
GROUP BY
    e.database_name
  , e.client_app_name
  , e.client_hostname
ORDER BY total_erros DESC;

/* ============================================================================
   SEÇÃO 5 — ERROS CRÍTICOS (severidade >= 20)
   Filtro de prioridade máxima. Severidade 20+ significa processo ou
   conexão terminada, risco de corrupção ou falha de hardware.
   Estes são os erros que exigem ação imediata, não análise.
   ============================================================================ */
SELECT TOP (@TopN)
    e.Dt_Evento
  , e.severity
  , e.error_number
  , e.[state]
  , e.database_name
  , e.username
  , e.client_hostname
  , e.client_app_name
  , e.session_id
  , LEFT(e.message, 1000)                                              AS mensagem
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
  AND e.severity >= 20
ORDER BY e.Dt_Evento DESC, e.severity DESC;

/* ============================================================================
   SEÇÃO 6 — ERROS DE CORRUPÇÃO E I/O (823, 824, 825, 832, 855)
   Lista nominal dos erros que indicam problema físico de armazenamento.
   Estes exigem DBCC CHECKDB e verificação de hardware, não ajuste de query.
   ============================================================================ */
SELECT TOP (@TopN)
    e.Dt_Evento
  , e.error_number
  , CASE e.error_number
        WHEN 823 THEN '823 - Falha de I/O: sistema operacional recusou leitura/escrita'
        WHEN 824 THEN '824 - Pagina corrompida: checksum invalido ou torn page'
        WHEN 825 THEN '825 - Leitura falhou e teve sucesso na retentativa'
        WHEN 832 THEN '832 - Pagina alterada desde a ultima escrita (constante)'
        WHEN 855 THEN '855 - Corrupcao de pagina nao reparavel'
        ELSE 'Outro erro de integridade'
    END                                                                AS descricao
  , e.severity
  , e.database_name
  , e.client_hostname
  , e.session_id
  , LEFT(e.message, 1000)                                              AS mensagem
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
  AND e.error_number IN (823, 824, 825, 832, 855)
ORDER BY e.Dt_Evento DESC;

/* ============================================================================
   SEÇÃO 7 — ERROS DE EXAUSTÃO DE RECURSO (severidade 17)
   Memória, locks, espaço em disco, threads. São os erros mais frequentes
   no escopo desta coleta. Agrupa por error_number para ver qual recurso
   está sob pressão.
   ============================================================================ */
SELECT TOP (@TopN)
    e.error_number
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT e.database_name)                                AS bancos_afetados
  , MAX(LEFT(e.message, 500))                                          AS mensagem_representativa
  , MIN(e.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(e.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
  AND e.severity = 17
GROUP BY e.error_number
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 8 — ERROS POR LOGIN E SESSÃO
   Quem está provocando os erros. Um login com volume alto e poucos erros
   distintos indica problema sistemático de código ou de permissão.
   ============================================================================ */
SELECT TOP (@TopN)
    e.username                                                         AS login_name
  , e.client_hostname                                                  AS host
  , e.client_app_name                                                  AS aplicacao
  , COUNT_BIG(*)                                                       AS total_erros
  , COUNT_BIG(DISTINCT e.error_number)                                 AS erros_distintos
  , COUNT_BIG(DISTINCT e.session_id)                                   AS sessoes_distintas
  , MAX(e.severity)                                                    AS maior_severidade
  , MIN(e.Dt_Evento)                                                   AS primeira_ocorrencia
  , MAX(e.Dt_Evento)                                                   AS ultima_ocorrencia
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
GROUP BY
    e.username
  , e.client_hostname
  , e.client_app_name
ORDER BY total_erros DESC;

/* ============================================================================
   SEÇÃO 9 — ERROS POR STATE (variação do mesmo erro)
   O campo state diferencia a origem interna do mesmo error_number.
   Erros com muitos states distintos indicam múltiplos caminhos de falha
   dentro do mesmo código de erro — informação que o error_number sozinho
   esconde.
   ============================================================================ */
SELECT TOP (@TopN)
    e.error_number
  , e.[state]
  , e.severity
  , COUNT_BIG(*)                                                       AS ocorrencias
  , COUNT_BIG(DISTINCT e.database_name)                                AS bancos_afetados
  , MAX(LEFT(e.message, 300))                                          AS mensagem_representativa
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
GROUP BY
    e.error_number
  , e.[state]
  , e.severity
ORDER BY ocorrencias DESC;

/* ============================================================================
   SEÇÃO 10 — TIMELINE DE UM ERRO ESPECÍFICO (drill-down)
   Dado um error_number, mostra a evolução temporal: quantas ocorrências
   por hora, em quais bancos e por quais aplicações.
   Substitua @ErrorNumberAlvo pelo código investigado.
   ============================================================================ */
DECLARE @ErrorNumberAlvo INT = NULL;   -- ex.: 17806, 823, 1204

SELECT
    CONVERT(DATE, e.Dt_Evento)                                         AS dia
  , DATEPART(HOUR, e.Dt_Evento)                                        AS hora
  , e.database_name                                                    AS banco
  , e.client_app_name                                                  AS aplicacao
  , COUNT_BIG(*)                                                       AS ocorrencias
  , MAX(e.severity)                                                    AS severidade
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
  AND (@ErrorNumberAlvo IS NULL OR e.error_number = @ErrorNumberAlvo)
GROUP BY
    CONVERT(DATE, e.Dt_Evento)
  , DATEPART(HOUR, e.Dt_Evento)
  , e.database_name
  , e.client_app_name
ORDER BY dia DESC, hora DESC, ocorrencias DESC;

/* ============================================================================
   SEÇÃO 11 — DETALHE CRONOLÓGICO (investigação manual)
   Últimos erros com todas as colunas relevantes.
   ============================================================================ */
SELECT TOP (200)
    e.Dt_Evento
  , e.severity
  , e.error_number
  , e.[state]
  , e.database_name
  , e.username
  , e.client_hostname
  , e.client_app_name
  , e.session_id
  , e.message
  , CASE WHEN e.sql_text IS NULL THEN 'NULL (CAST falhou na carga)' ELSE 'SQL presente' END AS status_sql_text
FROM dbo.history_database_error AS e WITH (NOLOCK)
WHERE e.Dt_Evento >= @DataInicial
  AND e.Dt_Evento <  @DataFinal
ORDER BY e.Dt_Evento DESC;
