/*
 *
    OBJETIVO: Visualização e análise de relatórios de blocked process report coletados
              por trace, tabela, arquivo XML ou sessão de Extended Events.

    PROJETO: mssql-xe-observability

    AUTHOR: Michael J. Swart

    REFERÊNCIAS DE URL:
 *  https://michaeljswart.com/2016/02/look-at-blocked-process-reports-collected-with-extended-events/
 *  https://michaeljswart.com/2011/04/a-new-way-to-examine-blocked-process-reports/
 */
USE DBA_PerformanceHub
GO

-- ============================================================
-- Criação inicial da procedure como placeholder
-- ============================================================
IF OBJECT_ID('sp_blocked_process_report_viewer') IS NULL
BEGIN
    EXEC ('
    CREATE PROCEDURE dbo.sp_blocked_process_report_viewer
    AS
    SELECT ''Replace Me''')
END
GO

-- ============================================================
-- Procedure dbo.sp_blocked_process_report_viewer
-- Analisa blocked process reports a partir de diferentes origens.
-- ============================================================
ALTER PROCEDURE dbo.sp_blocked_process_report_viewer
(
    @Source NVARCHAR(MAX)
  , @Type VARCHAR(10) = 'FILE'
)
WITH ENCRYPTION
AS
BEGIN
    SET NOCOUNT ON

    -- ============================================================
    -- Validação do tipo de origem
    -- ============================================================
    IF (@Type NOT IN ('FILE', 'TABLE', 'XMLFILE', 'XESESSION'))
    BEGIN
        RAISERROR('The @Type parameter must be ''FILE'', ''TABLE'', ''XESESSION'' or ''XMLFILE''', 11, 1)
    END

    IF (@Source LIKE '%.trc' AND @Type <> 'FILE')
    BEGIN
        RAISERROR('Warning: You specified a .trc trace. You should also specify @Type = ''FILE''', 10, 1)
    END

    IF (@Source LIKE '%.xml' AND @Type <> 'XMLFILE')
    BEGIN
        RAISERROR('Warning: You specified a .xml trace. You should also specify @Type = ''XMLFILE''', 10, 1)
    END

    IF (@Type = 'XESESSION' AND NOT EXISTS
    (
        SELECT *
        FROM sys.server_event_sessions AS es
        INNER JOIN sys.server_event_session_targets AS est
            ON es.event_session_id = est.event_session_id
        WHERE est.name IN ('event_file', 'ring_buffer')
        AND es.name = @Source
    ))
    BEGIN
        RAISERROR('Warning: The extended event session you supplied does not exist or does not have an "event_file" or "ring_buffer" target.', 10, 1);
    END

    -- ============================================================
    -- Tabela temporária para os relatórios shreddados
    -- ============================================================
    CREATE TABLE #ReportsXML
    (
        monitorloop NVARCHAR(100) NOT NULL
      , endTime DATETIME NULL
      , blocking_spid INT NOT NULL
      , blocking_ecid INT NOT NULL
      , blocked_spid INT NOT NULL
      , blocked_ecid INT NOT NULL
      , blocked_hierarchy_string AS CAST(blocked_spid AS VARCHAR(20)) + '.' + CAST(blocked_ecid AS VARCHAR(20)) + '/'
      , blocking_hierarchy_string AS CAST(blocking_spid AS VARCHAR(20)) + '.' + CAST(blocking_ecid AS VARCHAR(20)) + '/'
      , bpReportXml XML NOT NULL
      , PRIMARY KEY CLUSTERED (monitorloop, blocked_spid, blocked_ecid)
      , UNIQUE NONCLUSTERED (monitorloop, blocking_spid, blocking_ecid, blocked_spid, blocked_ecid)
    )

    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @TableSource NVARCHAR(MAX);

    -- ============================================================
    -- Definição da origem para tabela
    -- ============================================================
    IF (@Type = 'TABLE')
    BEGIN
        SET @TableSource = ISNULL(QUOTENAME(PARSENAME(@Source, 4)) + N'.', '')
            + ISNULL(QUOTENAME(PARSENAME(@Source, 3)) + N'.', '')
            + ISNULL(QUOTENAME(PARSENAME(@Source, 2)) + N'.', '')
            + QUOTENAME(PARSENAME(@Source, 1));
    END

    -- ============================================================
    -- Definição da origem para arquivo de trace
    -- ============================================================
    IF (@Type = 'FILE')
    BEGIN
        SET @TableSource = N'sys.fn_trace_gettable(N' + QUOTENAME(@Source, '''') + ', -1)';
    END

    -- ============================================================
    -- Carga dos dados de tabela ou arquivo de trace
    -- ============================================================
    IF (@Type IN ('TABLE', 'FILE'))
    BEGIN
        SET @SQL = N'
        INSERT #ReportsXML
        (
            blocked_ecid
          , blocked_spid
          , blocking_ecid
          , blocking_spid
          , monitorloop
          , bpReportXml
          , endTime
        )
        SELECT
            blocked_ecid
          , blocked_spid
          , blocking_ecid
          , blocking_spid
          , COALESCE(monitorloop, CONVERT(NVARCHAR(100), endTime, 120), CAST(NEWID() AS NVARCHAR(100)))
          , bpReportXml
          , EndTime
        FROM ' + @TableSource + N'
        CROSS APPLY
        (
            SELECT CAST(TextData AS XML)
        ) AS bpReports(bpReportXml)
        CROSS APPLY
        (
            SELECT
                monitorloop = bpReportXml.value(''(//@monitorLoop)[1]'', ''NVARCHAR(100)'')
              , blocked_spid = bpReportXml.value(''(/blocked-process-report/blocked-process/process/@spid)[1]'', ''INT'')
              , blocked_ecid = bpReportXml.value(''(/blocked-process-report/blocked-process/process/@ecid)[1]'', ''INT'')
              , blocking_spid = bpReportXml.value(''(/blocked-process-report/blocking-process/process/@spid)[1]'', ''INT'')
              , blocking_ecid = bpReportXml.value(''(/blocked-process-report/blocking-process/process/@ecid)[1]'', ''INT'')
        ) AS bpShredded
        WHERE --EventClass = 137
        --AND
            blocking_spid IS NOT NULL
            AND blocked_spid IS NOT NULL';

        EXEC (@SQL);
    END

    -- ============================================================
    -- Carga dos dados de sessão de Extended Events
    -- ============================================================
    IF (@Type = 'XESESSION')
    BEGIN
        DECLARE @SessionType NVARCHAR(MAX);
        DECLARE @SessionId INT;
        DECLARE @SessionTargetId INT;
        DECLARE @FilenamePattern NVARCHAR(MAX);

        SELECT TOP (1)
            @SessionType = est.name
          , @SessionId = est.event_session_id
          , @SessionTargetId = est.target_id
        FROM sys.server_event_sessions AS es
        INNER JOIN sys.server_event_session_targets AS est
            ON es.event_session_id = est.event_session_id
        WHERE est.name IN ('event_file', 'ring_buffer')
        AND es.name = @Source;

        IF (@SessionType = 'event_file')
        BEGIN
            SELECT @FilenamePattern = REPLACE(CAST([value] AS NVARCHAR(MAX)), '.xel', '*xel')
            FROM sys.server_event_session_fields
            WHERE event_session_id = @SessionId
            AND [object_id] = @SessionTargetId
            AND name = 'filename';

            IF (@FilenamePattern NOT LIKE '%xel')
            BEGIN
                SET @FilenamePattern += '*xel';
            END

            INSERT #ReportsXML
            (
                blocked_ecid
              , blocked_spid
              , blocking_ecid
              , blocking_spid
              , monitorloop
              , bpReportXml
              , endTime
            )
            SELECT
                blocked_ecid
              , blocked_spid
              , blocking_ecid
              , blocking_spid
              , COALESCE(monitorloop, CONVERT(NVARCHAR(100), eventDate, 120), CAST(NEWID() AS NVARCHAR(100)))
              , bpReportXml
              , eventDate
            FROM sys.fn_xe_file_target_read_file(@FilenamePattern, NULL, NULL, NULL) AS event_file_value
            CROSS APPLY
            (
                SELECT CAST(event_file_value.[event_data] AS XML)
            ) AS event_file_value_xml ([xml])
            CROSS APPLY
            (
                SELECT
                    event_file_value_xml.[xml].value('(event/@timestamp)[1]', 'DATETIME') AS eventDate
                  , event_file_value_xml.[xml].query('//event/data/value/blocked-process-report') AS bpReportXml
            ) AS bpReports
            CROSS APPLY
            (
                SELECT
                    monitorloop = bpReportXml.value('(//@monitorLoop)[1]', 'NVARCHAR(100)')
                  , blocked_spid = bpReportXml.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'INT')
                  , blocked_ecid = bpReportXml.value('(/blocked-process-report/blocked-process/process/@ecid)[1]', 'INT')
                  , blocking_spid = bpReportXml.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'INT')
                  , blocking_ecid = bpReportXml.value('(/blocked-process-report/blocking-process/process/@ecid)[1]', 'INT')
            ) AS bpShredded
            WHERE blocking_spid IS NOT NULL
            AND blocked_spid IS NOT NULL;
        END
        ELSE IF (@SessionType = 'ring_buffer')
        BEGIN
            -- Leitura dos dados do ring buffer
            INSERT #ReportsXML
            (
                blocked_ecid
              , blocked_spid
              , blocking_ecid
              , blocking_spid
              , monitorloop
              , bpReportXml
              , endTime
            )
            SELECT
                blocked_ecid
              , blocked_spid
              , blocking_ecid
              , blocking_spid
              , COALESCE(monitorloop, CONVERT(NVARCHAR(100), bpReportEndTime, 120), CAST(NEWID() AS NVARCHAR(100)))
              , bpReportXml
              , bpReportEndTime
            FROM sys.dm_xe_session_targets AS st
            INNER JOIN sys.dm_xe_sessions AS s
                ON s.address = st.event_session_address
            CROSS APPLY
            (
                SELECT CAST(st.target_data AS XML)
            ) AS TargetData ([xml])
            CROSS APPLY TargetData.[xml].nodes('/RingBufferTarget/event[@name="blocked_process_report"]') AS bpNodes(bpNode)
            CROSS APPLY bpNode.nodes('./data[@name="blocked_process"]/value/blocked-process-report') AS bpReportXMLNodes(bpReportXMLNode)
            CROSS APPLY
            (
                SELECT
                    bpReportXml = CAST(bpReportXMLNode.query('.') AS XML)
                  , bpReportEndTime = bpNode.value('(./@timestamp)[1]', 'DATETIME')
                  , monitorloop = bpReportXMLNode.value('(//@monitorLoop)[1]', 'NVARCHAR(100)')
                  , blocked_spid = bpReportXMLNode.value('(./blocked-process/process/@spid)[1]', 'INT')
                  , blocked_ecid = bpReportXMLNode.value('(./blocked-process/process/@ecid)[1]', 'INT')
                  , blocking_spid = bpReportXMLNode.value('(./blocking-process/process/@spid)[1]', 'INT')
                  , blocking_ecid = bpReportXMLNode.value('(./blocking-process/process/@ecid)[1]', 'INT')
            ) AS bpShredded
            WHERE s.name = @Source
            OPTION (MAXDOP 1);
        END
    END

    -- ============================================================
    -- Carga dos dados de arquivo XML
    -- ============================================================
    IF (@Type = 'XMLFILE')
    BEGIN
        CREATE TABLE #TraceXML
        (
            id INT IDENTITY PRIMARY KEY
          , ReportXML XML NOT NULL
        )

        SET @SQL = N'
        INSERT #TraceXML
        (
            ReportXML
        )
        SELECT col
        FROM OPENROWSET
        (
            BULK ' + QUOTENAME(@Source, '''') + N', SINGLE_BLOB
        ) AS xmldata(col)';

        EXEC (@SQL);

        CREATE PRIMARY XML INDEX PXML_TraceXML
        ON #TraceXML(ReportXML);

        WITH XMLNAMESPACES
        (
            'http://tempuri.org/TracePersistence.xsd' AS MY
        )
        , ShreddedWheat AS
        (
            SELECT
                bpShredded.blocked_ecid
              , bpShredded.blocked_spid
              , bpShredded.blocking_ecid
              , bpShredded.blocking_spid
              , bpShredded.monitorloop
              , bpReports.bpReportXml
              , bpReports.bpReportEndTime
            FROM #TraceXML
            CROSS APPLY ReportXML.nodes('/MY:TraceData/MY:Events/MY:Event[@name="Blocked process report"]') AS eventNodes(eventNode)
            CROSS APPLY eventNode.nodes('./MY:Column[@name="EndTime"]') AS endTimeNodes(endTimeNode)
            CROSS APPLY eventNode.nodes('./MY:Column[@name="TextData"]') AS bpNodes(bpNode)
            CROSS APPLY
            (
                SELECT
                    CAST(bpNode.value('(./text())[1]', 'NVARCHAR(MAX)') AS XML)
                  , CAST(LEFT(endTimeNode.value('(./text())[1]', 'VARCHAR(MAX)'), 19) AS DATETIME)
            ) AS bpReports(bpReportXml, bpReportEndTime)
            CROSS APPLY
            (
                SELECT
                    monitorloop = bpReportXml.value('(//@monitorLoop)[1]', 'NVARCHAR(100)')
                  , blocked_spid = bpReportXml.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'INT')
                  , blocked_ecid = bpReportXml.value('(/blocked-process-report/blocked-process/process/@ecid)[1]', 'INT')
                  , blocking_spid = bpReportXml.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'INT')
                  , blocking_ecid = bpReportXml.value('(/blocked-process-report/blocking-process/process/@ecid)[1]', 'INT')
            ) AS bpShredded
        )
        INSERT #ReportsXML
        (
            blocked_ecid
          , blocked_spid
          , blocking_ecid
          , blocking_spid
          , monitorloop
          , bpReportXml
          , endTime
        )
        SELECT
            blocked_ecid
          , blocked_spid
          , blocking_ecid
          , blocking_spid
          , COALESCE(monitorloop, CONVERT(NVARCHAR(100), bpReportEndTime, 120), 'unknown')
          , bpReportXml
          , bpReportEndTime
        FROM ShreddedWheat;

        DROP TABLE #TraceXML
    END

    -- ============================================================
    -- Organização e seleção hierárquica dos relatórios
    -- ============================================================
    ;WITH Blockheads AS
    (
        SELECT
            blocking_spid
          , blocking_ecid
          , monitorloop
          , blocking_hierarchy_string
        FROM #ReportsXML
        EXCEPT
        SELECT
            blocked_spid
          , blocked_ecid
          , monitorloop
          , blocked_hierarchy_string
        FROM #ReportsXML
    )
    , Hierarchy AS
    (
        SELECT
            monitorloop
          , blocking_spid AS spid
          , blocking_ecid AS ecid
          , CAST('/' + blocking_hierarchy_string AS VARCHAR(MAX)) AS chain
          , 0 AS level
        FROM Blockheads
        UNION ALL
        SELECT
            irx.monitorloop
          , irx.blocked_spid
          , irx.blocked_ecid
          , CAST(h.chain + irx.blocked_hierarchy_string AS VARCHAR(MAX))
          , h.level + 1
        FROM #ReportsXML AS irx
        INNER JOIN Hierarchy AS h
            ON irx.monitorloop = h.monitorloop
            AND irx.blocking_spid = h.spid
            AND irx.blocking_ecid = h.ecid
    )
    SELECT
        ISNULL(CONVERT(NVARCHAR(30), irx.endTime, 120), 'Lead') AS traceTime
      , SPACE(4 * h.level) + CAST(h.spid AS VARCHAR(20)) + CASE h.ecid WHEN 0 THEN '' ELSE '(' + CAST(h.ecid AS VARCHAR(20)) + ')' END AS blockingTree
      , irx.bpReportXml
    FROM Hierarchy AS h
    LEFT JOIN #ReportsXML AS irx
        ON irx.monitorloop = h.monitorloop
        AND irx.blocked_spid = h.spid
        AND irx.blocked_ecid = h.ecid
    ORDER BY
        h.monitorloop
      , h.chain

    DROP TABLE #ReportsXML
END
GO
