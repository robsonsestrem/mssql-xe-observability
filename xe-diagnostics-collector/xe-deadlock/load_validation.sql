/*
 *
    OBJETIVO: Validação da integridade de carga entre as tabelas
              history_deadlocks_details e history_deadlock_xml_events,
              comparando, evento por evento, quantos processos a tabela
              de detalhes registrou versus quantos o XML contém, com
              identificação de divergências e diagnóstico de causa.

    PROJETO: mssql-xe-observability

    AUTHOR: Robson Sestrem 

    REFERÊNCIAS DE URL:
 *  Documentação oficial: FULL OUTER JOIN, OUTER APPLY, XML value(), COUNT_BIG
 */
-- ==================================================================================
-- SEÇÃO A — Correlação entre as duas tabelas
-- ----------------------------------------------------------------------------------
-- Valida a integridade da carga comparando, evento por evento, quantos
-- processos a tabela de detalhes registrou versus quantos o XML contém.
-- A divergência entre essas contagens é o indicador real de problema
-- na carga, não a simples existência do XML.
--
-- SUPOSIÇÕES:
--   - dt_event e xeTimeStamp representam o mesmo instante do evento.
--     Se houver divergência de milissegundos na origem, o LEFT JOIN por
--     igualdade exata vai gerar falsos 'SEM_XML'. Nesse caso, use a
--     versão alternativa ao final desta seção (join por janela de tempo).
--   - processId corresponde ao atributo @id do <process> no XML.
-- ==================================================================================
USE DBA_PerformanceHub
GO

DECLARE @DataInicial DATETIME2(3) = DATEADD(DAY, -7, SYSDATETIME())
DECLARE @DataFinal   DATETIME2(3) = SYSDATETIME()
DECLARE @TopN        INT          = 50

;WITH detalhe AS
(
    SELECT
          d.dt_event
        , COUNT_BIG(*) AS qtd_processos_detalhe
        , SUM(CASE WHEN d.isVictim = 1 THEN 1 ELSE 0 END) AS qtd_vitimas_detalhe
        , COUNT_BIG(DISTINCT d.processId) AS process_ids_distintos
        , MAX(d.processSPID) AS maior_spid
    FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
    WHERE d.dt_event >= @DataInicial
        AND d.dt_event < @DataFinal
    GROUP BY d.dt_event
)
, xml_ev AS
(
    SELECT
          x.xeTimeStamp
        , COUNT_BIG(*) AS linhas_xml
        , MAX(x.xeXML.value('count(/event/data/value/deadlock/process-list/process)', 'int')) AS qtd_processos_no_xml
        , MAX(x.xeXML.value('count(/event/data/value/deadlock/victim-list/victimProcess)', 'int')) AS qtd_vitimas_no_xml
        , MAX(x.xeXML.value('(/event/action[@name="session_id"]/value)[1]', 'int')) AS session_id_real
        , MAX(x.xeXML.value('(/event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')) AS client_app_name
        , MAX(x.xeXML.value('(/event/action[@name="database_name"]/value)[1]', 'nvarchar(128)')) AS database_name
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    WHERE x.xeTimeStamp >= @DataInicial
        AND x.xeTimeStamp < @DataFinal
    GROUP BY x.xeTimeStamp
)
SELECT TOP (@TopN)
      COALESCE(dt.dt_event, xm.xeTimeStamp) AS dt_event
    , CASE
          WHEN dt.dt_event IS NULL THEN 'SEM_DETALHE'
          WHEN xm.xeTimeStamp IS NULL THEN 'SEM_XML'
          ELSE 'OK'
      END AS status_carga
    , dt.qtd_processos_detalhe
    , xm.qtd_processos_no_xml
    , dt.qtd_processos_detalhe - xm.qtd_processos_no_xml AS dif_processos
    , dt.qtd_vitimas_detalhe
    , xm.qtd_vitimas_no_xml
    , dt.qtd_vitimas_detalhe - xm.qtd_vitimas_no_xml AS dif_vitimas
    , dt.process_ids_distintos
    , xm.linhas_xml
    , xm.session_id_real
    , xm.client_app_name
    , xm.database_name
    , CASE
          WHEN dt.dt_event IS NULL
              THEN 'Evento presente apenas no XML — carga de detalhes nao processou.'
          WHEN xm.xeTimeStamp IS NULL
              THEN 'Evento presente apenas no detalhe — XML ausente ou timestamp divergente.'
          WHEN dt.qtd_processos_detalhe <> xm.qtd_processos_no_xml
              THEN 'Divergencia de processos entre detalhe e XML — investigar carga.'
          WHEN dt.qtd_vitimas_detalhe <> xm.qtd_vitimas_no_xml
              THEN 'Divergencia de vitimas — isVictim possivelmente inconsistente.'
          WHEN dt.process_ids_distintos <> dt.qtd_processos_detalhe
              THEN 'processId duplicado no detalhe para o mesmo evento.'
          ELSE 'Carga consistente.'
      END AS diagnostico
FROM detalhe AS dt
    FULL OUTER JOIN xml_ev AS xm
        ON xm.xeTimeStamp = dt.dt_event
ORDER BY dt_event DESC

-- ==================================================================================
-- SEÇÃO B — Correlação por janela de tempo (fallback)
-- ----------------------------------------------------------------------------------
-- Use quando a Seção A retornar muitos 'SEM_XML' em eventos que deveriam
-- ter XML. A janela de ±2 segundos absorve divergência de milissegundos
-- entre o timestamp do evento e o timestamp do processo.
--
-- ATENÇÃO: em ambientes com deadlocks muito frequentes (vários por segundo),
-- a janela pode casar o evento errado. Confira a coluna dif_segundos antes
-- de confiar no resultado.
-- ==================================================================================
;WITH detalhe AS
(
    SELECT
          d.dt_event
        , COUNT_BIG(*) AS qtd_processos_detalhe
        , SUM(CASE WHEN d.isVictim = 1 THEN 1 ELSE 0 END) AS qtd_vitimas_detalhe
    FROM dbo.history_deadlocks_details AS d WITH (NOLOCK)
    WHERE d.dt_event >= @DataInicial
        AND d.dt_event < @DataFinal
    GROUP BY d.dt_event
)
, xml_ev AS
(
    SELECT
          x.xeTimeStamp
        , MAX(x.xeXML.value('count(/event/data/value/deadlock/process-list/process)', 'int')) AS qtd_processos_no_xml
        , MAX(x.xeXML.value('count(/event/data/value/deadlock/victim-list/victimProcess)', 'int')) AS qtd_vitimas_no_xml
    FROM dbo.history_deadlock_xml_events AS x WITH (NOLOCK)
    WHERE x.xeTimeStamp >= @DataInicial
        AND x.xeTimeStamp < @DataFinal
    GROUP BY x.xeTimeStamp
)
SELECT TOP (@TopN)
      dt.dt_event
    , xm.xeTimeStamp AS xml_timestamp
    , DATEDIFF(MILLISECOND, dt.dt_event, xm.xeTimeStamp) AS dif_ms
    , dt.qtd_processos_detalhe
    , xm.qtd_processos_no_xml
    , dt.qtd_vitimas_detalhe
    , xm.qtd_vitimas_no_xml
    , CASE
          WHEN xm.xeTimeStamp IS NULL THEN 'SEM_XML'
          WHEN dt.qtd_processos_detalhe <> xm.qtd_processos_no_xml THEN 'DIVERGENCIA'
          ELSE 'OK'
      END AS status_carga
FROM detalhe AS dt
    OUTER APPLY
    (
        SELECT TOP (1)
              x.xeTimeStamp
            , x.qtd_processos_no_xml
            , x.qtd_vitimas_no_xml
        FROM xml_ev AS x
        WHERE ABS(DATEDIFF(MILLISECOND, dt.dt_event, x.xeTimeStamp)) <= 2000
        ORDER BY ABS(DATEDIFF(MILLISECOND, dt.dt_event, x.xeTimeStamp))
    ) AS xm
ORDER BY dt.dt_event DESC

