# 🗄️ mssql-xe-observability

**Coleta e histórico de diagnósticos de performance no SQL Server via Extended Events — em Linux**

[![SQL Server](https://img.shields.io/badge/SQL_Server-2017%2B-CC2927?style=flat-square&logo=microsoftsqlserver&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-Amazon_Linux_2-FCC624?style=flat-square&logo=linux&logoColor=black)](#)
[![T-SQL](https://img.shields.io/badge/T--SQL-SQL_Server_Agent-4479A1?style=flat-square)](#)
[![Licença](https://img.shields.io/badge/Licen%C3%A7a-MIT-green?style=flat-square)](#-licença)

---

## 📖 Visão Geral

Este repositório reúne um conjunto de rotinas T-SQL e scripts operacionais para **observabilidade de instâncias SQL Server em Linux**, construídas sobre **Extended Events (XE)**.

A proposta é substituir a coleta ad-hoc de diagnóstico — aquela investigação feita "na hora do incidente", com queries avulsas em DMVs e sessões de XE criadas manualmente — por um **histórico persistente e consultável** de eventos relevantes de performance, concorrência e integridade de código.

O projeto é organizado como um **projeto de banco de dados SQL (`.sqlproj`)** com SDK `Microsoft.Build.Sql`, o que permite versionamento, build e publicação dos objetos via pipeline — e não apenas como uma pasta de scripts soltos.

O repositório implementa um padrão repetido e consistente para cada tipo de diagnóstico:

1. **Sessão de Extended Events** (`CREATE EVENT SESSION ... ON SERVER`) com eventos, actions e predicados filtrados para reduzir volume.
2. **Target `package0.event_file`** apontando para arquivos `.xel` com tamanho máximo e rollover definidos.
3. **Tabela de histórico** no banco `DBA_PerformanceHub` (schema `dbo`), com compressão de página e índice clusterizado por data.
4. **Stored procedure de carga** (`sp_load_*` / `sp_gather_*`) que lê os arquivos com `sys.fn_xe_file_target_read_file`, faz *shredding* do XML e insere apenas os eventos posteriores ao último registro carregado.
5. **Job do SQL Server Agent** na categoria `Data Collector`, com agendamento recorrente, executando a procedure de carga.
6. **Rotinas de retenção** — jobs de limpeza de histórico no `msdb` e de expurgo de arquivos `.xel` no sistema de arquivos (bash + cron).

O resultado é um pipeline **XE → arquivo → tabela → análise**, sem dependência de ferramentas de terceiros.

> Projeto com forte viés operacional: nasceu de um ambiente real de produção.

---

## 🎯 Objetivo do Repositório

O objetivo central é responder, com evidência histórica, perguntas que todo DBA enfrenta:

- **Por que a aplicação travou ontem às 14h?** (deadlocks, bloqueios, timeouts)
- **Qual query consome mais CPU e I/O ao longo da semana?** (queries caras, waits, percentis)
- **Onde no código nasce o conflito de locks?** (pilha de execução, procedures envolvidas)
- **O plano foi degradado por conversão implícita?** (plan affecting convert)
- **Houve mudança de estrutura não planejada?** (DDL: CREATE/ALTER/DROP)
- **A instância está sofrendo com memory grant insuficiente?** (sort warnings)
- **Quem está causando fragmentação por page splits?** (transaction_log, operação 11)

Em vez de "monitorar tudo", o repositório adota uma abordagem **orientada a sintomas conhecidos**: cada pasta representa um tipo de evento que já se sabe ser causa recorrente de problema em produção, por exemplo:
- **Correlação temporal** entre diferentes fenômenos (ex.: pico de waits + recompilações + conversões implícitas na mesma janela).
- **Padronização** de coleta entre instâncias, com nomenclatura e estrutura de tabelas uniformes.
- **Automação** completa: as sessões sobem com a instância (`STARTUP_STATE = ON`) e os jobs carregam os dados periodicamente.
---

## 🧱 Estrutura e Organização

mssql-xe-observability/
├── xe-diagnostics-collector/          # Projeto SQL (SSDT / Microsoft.Build.Sql)
│   ├── xe-diagnostics-collector.sqlproj
│   ├── xe-diagnostics-collector.slnx
│   ├── retention/                     # Retenção de dados e de arquivos .xel
│   │   ├── job_monitoring_log_cleanup.sql
│   │   ├── job_purge_job_collection_history.sql
│   │   ├── job_purge_job_history.sql
│   │   └── retention-files-xel-linux/ # Rotina bash + cron para limpar .xel
│   ├── xe-convert-implicit/           # Conversão implícita (plan_affecting_convert)
│   ├── xe-ddl-statements/             # DDL (object_created/altered/deleted)
│   ├── xe-deadlock/                   # Deadlocks (xml_deadlock_report)
│   ├── xe-error-reported/             # Erros de severidade >= 17
│   ├── xe-expansive-querys/           # Queries caras / lentas
│   ├── xe-lock-block/                 # Bloqueios (blocked_process_report)
│   ├── xe-page-split/                 # Page splits (transaction_log)
│   ├── xe-sort-warning/               # Sort warnings / memory grant
│   ├── xe-statement-recompile/        # Recompilações (sql_statement_recompile)
│   ├── xe-timeouts/                   # Timeouts e conexões interrompidas (attention)
│   └── xe-wait-info/                  # Waits e estatísticas de execução
├── .gitignore
├── LICENSE                            # MIT
└── README.md


### Convenção de nomes dentro de cada pasta

Cada diretório de diagnóstico segue o mesmo padrão de arquivos:

| Prefixo | Papel |
|---|---|
| `poc_*.sql` | Prova de conceito: cria a sessão XE, as tabelas de histórico e a procedure de carga |
| `job_*.sql` | Criação do SQL Server Agent Job que executa a procedure de carga |
| `analysis_*.sql` | Consultas analíticas sobre as tabelas de histórico |

---

## 🧩 Principais categorias de conteúdo

### 🔒 Concorrência e bloqueios

- **Deadlocks** — sessão `deadlocks` sobre `sqlserver.xml_deadlock_report`, com duas tabelas: `history_deadlocks_details` (uma linha por processo) e `history_deadlock_xml_events` (grafo XML completo). Procedures: `sp_load_deadlocks` e `sp_gather_deadlock_events`. O script também configura `blocked process threshold` em 5 segundos.
- **Bloqueios** — sessão `blocked_process` sobre `sqlserver.blocked_process_report`, tabela `history_blocked_process` e procedure `sp_gather_blocked_process_events`.
- **Visualizador de blocked process report** — `sp_blocked_process_report_viewer`, procedure que lê relatórios de bloqueio de quatro origens (`FILE`, `TABLE`, `XMLFILE`, `XESESSION`), incluindo leitura de `ring_buffer` e de arquivos `.xel`. Crédito no cabeçalho: **Michael J. Swart**.

### ⏱️ Performance de queries

- **Waits e estatísticas de execução** — sessão `query_performance_wait_info` combinando `sqlos.wait_info`, `sqlserver.sp_statement_completed` e `sqlserver.sql_statement_completed`. Tabelas: `history_wait_info_xevents` (XML bruto), `history_waits` e `history_query_stats`. Procedure: `sp_load_query_performance_wait_info`.
- **Queries caras** — coleta de queries com duração acima de 10 segundos, via `sp_load_slow_query_statement` e `sp_load_slow_query_batch_rpc`, com tabelas `history_slow_query_statement` e `history_slow_query_batch_rpc`.
- **Recompilações** — sessão `dark_queries_recompile` sobre `sqlserver.sql_statement_recompile`, filtrando `Option (recompile) requested`, `ADHOC` e `PREPARED`. Tabela `history_dark_queries_recompile`, procedure `sp_load_dark_queries_recompile`.
- **Sort warnings** — sessão `sort_warning_performance` sobre `sqlserver.sort_warning`, para diagnóstico de *memory grant* insuficiente. Tabela `history_sort_warning_performance`, procedure `sp_load_sort_warning_performance`.
- **Conversão implícita** — sessão `plan_affecting_convert` sobre `sqlserver.plan_affecting_convert`, filtrando `convert_issue = 'Seek Plan'`. Tabela `history_plan_affecting_convert`, procedure `sp_load_plan_affecting_convert`.

### 🧱 Estrutura física e alterações de schema

- **Page splits** — sessão `monitor_page_splits_<DATABASE>` sobre `sqlserver.transaction_log` com `operation = 11`, tabela `index_defrag_page_splits_<DATABASE>` e procedure `sp_load_index_defrag_insert_page_splits_<DATABASE>`. O script também ajusta `fill factor (%)`.
- **DDL** — sessão `collect_ddl_statement` sobre `object_altered`, `object_created` e `object_deleted`, filtrando `ddl_phase = 'Commit'` e excluindo `tempdb`/`master`. Tabela `history_ddl_statement`, procedure `sp_load_ddl_statement`.

### 🚨 Erros e interrupções

- **Erros do sistema** — sessão `system_error_collection` sobre `sqlserver.error_reported` com `severity >= 17`. Tabela `history_database_error`, procedure `sp_load_database_error`.
- **Timeouts** — sessão `monitoring_timeouts` sobre `sqlserver.attention`. Tabela `history_timeout`, procedure `sp_load_sessions_timeout`.

### 🧹 Retenção

- **`DBA - Monitoring_Log_Cleanup`** — 13 steps, um por tabela de histórico. Regra padrão: remove registros com mais de **15 dias**, preservando no mínimo **1.000 linhas**; para `history_ddl_statement` a regra é **120 dias** e **1.000.000 de linhas**. Executa a cada 2 semanas, aos domingos às 07:00.
- **`DBA - Purge_Job_Collection_History`** — executa `sp_purge_jobhistory` para cada job `DBA - Collect_*`, evitando crescimento do histórico do `msdb`. Terças, quintas e domingos às 19:00.
- **`job_purge_job_history.sql`** — variante adicional de expurgo de histórico de jobs.
- **`retention-files-xel-linux/`** — rotina bash para limpar os arquivos `.xel` no Linux, com *guarda de integridade*: só apaga se **todas** as últimas execuções dos jobs `%Collect%` tiverem `run_status = 0`. Fluxo: valida jobs → `stop_xe.sql` → `rm -rf` no diretório → `start_xe.sql`. Agendada via `cron` (`40 6 */2 * *`).

---

## 🔍 Padrões técnicos recorrentes

Vale destacar o que se repete em praticamente todos os scripts — valor arquitetural agregado no projeto:

- **Filtros agressivos na sessão XE**: exclusão de `database_id <= 4`, de `is_system = 1`, de `query_hash = 0` e do banco de monitoramento (`DBA_PerformanceHub`) — evitando o efeito de realimentação em que a coleta monitora a si mesma.
- **Carga incremental por watermark**: cada procedure lê `MAX(data)` da tabela de destino e processa apenas eventos posteriores, com `ISNULL(..., '1900-01-01')` como fallback.
- **Conversão de fuso horário** via `DATEDIFF(HOUR, GETUTCDATE(), GETDATE())` aplicada ao `timestamp_utc` dos eventos.
- **Shredding de XML** com `.value()` e `.nodes()`, incluindo extração de `tsql_stack`/`tsql_frame` combinada com `sys.dm_exec_sql_text` para recuperar o statement exato.
- **Tratamento transacional**: `BEGIN TRANSACTION` + `TRY/CATCH` + `SET XACT_ABORT ON`, com mensagem de erro enriquecida (`ERROR_LINE`, `ERROR_PROCEDURE`, `ERROR_STATE`).
- **Procedures com `WITH ENCRYPTION`** — o código interno das procedures de carga não é legível após a criação.
- **Compressão e índices**: `DATA_COMPRESSION = PAGE` e índice clusterizado por coluna de data nas tabelas de histórico.
- **Jobs criados em transação única** com `GOTO QuitWithRollback`, garantindo que uma falha no meio da criação não deixe job parcialmente configurado.
- **Categoria de job padronizada**: `Data Collector` (e `Database Maintenance` para a limpeza).

---

## 💡 Possíveis casos de uso

- **Diagnóstico de deadlocks recorrentes** — reconstruir o grafo de espera, identificar vítimas, recursos disputados (`KEY`, `PAGE`, `OBJECT`, `RID`) e a procedure/linha culpada.
- **Análise de contenção** — correlacionar bloqueios e waits com horários de pico e aplicações específicas (`client_app_name`, `client_hostname`).
- **Tuning baseado em evidência** — usar percentis (50/75/90/95/99) de duração, CPU e leituras para priorizar o que otimizar, em vez de agir por impressão.
- **Auditoria de mudanças de schema** — histórico de DDL com autor, host, aplicação e texto da instrução.
- **Governança de fragmentação** — rastrear page splits por índice/tabela e justificar revisão de fill factor.
- **Detecção de problemas de memory grant** — sort warnings com memória concedida vs. utilizada e row count real.
- **Investigação de timeouts** — identificar quais queries e aplicações estão sendo abortadas pelo cliente.
- **Baseline de performance** — acumular histórico para comparar comportamento antes/depois de releases.

---

## ✅ Benefícios para profissionais de banco de dados

- **Independência de ferramentas comerciais** — todo o pipeline é T-SQL + Agent + bash.
- **Baixo overhead por design** — predicados restritivos, `ALLOW_SINGLE_EVENT_LOSS` e rollover limitado de arquivos.
- **Retenção controlada em duas camadas** — arquivos `.xel` (curta duração, via cron) e tabelas (média duração, via jobs).
- **Consultas analíticas prontas** — os arquivos `analysis_*.sql` entregam rankings, séries temporais e drill-down sem exigir que você escreva o shredding do zero.
- **Padrão replicável** — a estrutura `poc_` / `job_` / `analysis_` serve como template para novos diagnósticos.
- **Compatível com SQL Server em Linux** — caminhos, `sqlcmd` em `/opt/mssql-tools/bin/` e agendamento por `cron` já previstos.

---

## 🚀 Como explorar e utilizar

### Pré-requisitos

- SQL Server com **SQL Server Agent** habilitado.
- Banco de histórico criado manualmente: **`DBA_PerformanceHub`** (o repositório não inclui script de criação do banco, o profissional deve criar com as devidas configurações).
- Permissão para `CREATE EVENT SESSION ... ON SERVER` (tipicamente `ALTER ANY EVENT SESSION`).
- Em Linux: `sqlcmd` disponível e diretório `/var/opt/mssql/log_jobs/xe` criado e com permissão de escrita para o usuário do SQL Server.

### Ordem sugerida de implantação

1. Criar o banco `DBA_PerformanceHub`.
2. Executar o `poc_*.sql` do diagnóstico desejado — ele cria a sessão XE, as tabelas e a procedure de carga.
3. Executar o `job_*.sql` correspondente para agendar a carga.
4. Validar com os scripts `analysis_*.sql`.
5. Implantar as rotinas de `retention/` para evitar crescimento indefinido.
6. Em Linux, configurar a limpeza de `.xel` conforme o README da pasta `retention-files-xel-linux`.

### Antes de rodar em produção — ajustes obrigatórios

Os scripts foram escritos para um ambiente específico e contêm valores que **precisam** ser revisados:

- `YOUR_DATABASE`, `YOUR_SERVER`, `YOUR_USER`, `YOUR_PASSWORD` — placeholders explícitos.
- `@owner_login_name = N'sa'` — troque pelo login de serviço adequado.
- Filtros por host fixo: `OSIRIS-DATABASE`, `OPTIMUS-PRIME`, `%WORKLOAD%`.
- Filtro por banco fixo em `plan_affecting_convert` (`N'HEALTHCARE_DEMO'`, marcado no código como `*** SEMPRE ATUALIZAR ***`) e em `sort_warning` (`N'YOUR_DATABASE'`).
- Exclusões de expressões de conversão implícita específicas de uma tabela (`[QUESTAO].[TIPO_QUESTAO]`).
- Caminhos de arquivo: `/var/opt/mssql/log_jobs/xe/` e `/var/opt/mssql/log_jobs/retention_xe/`.

---

## ⚠️ Observações importantes e limitações

- **Retenção por arquivo é destrutiva**: `rm -rf "$dir"/*` remove **todos** os arquivos do diretório, sem filtro por extensão ou idade. Confirme que o diretório contém apenas artefatos descartáveis.
- **Log consolidado sem rotação**: o wrapper `run_retention_xe.sh` usa `>>`, então `retention_xe.log` cresce indefinidamente.
- **Dependência de `sqlcmd` legado**: o caminho `/opt/mssql-tools/bin/sqlcmd` refere-se ao pacote `mssql-tools` (versão antiga); em distribuições recentes o caminho costuma ser `/opt/mssql-tools18/bin/sqlcmd`, com `-C` para confiar no certificado.
