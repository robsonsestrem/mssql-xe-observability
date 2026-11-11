# 🗄️ Retenção de Arquivos `.xel` — SQL Server em Linux (Amazon Linux 2)

Rotina operacional para limpar arquivos de Extended Events (`.xel`) em servidores SQL Server sobre Linux, com guarda de integridade baseada no histórico de jobs `%Collect%` do `msdb`.

---

## 🎯 Visão Geral

A rotina executa quatro etapas em sequência e **aborta imediatamente** se qualquer pré-condição falhar:

1. Valida se **todas** as últimas execuções dos jobs cujo nome contém `Collect` terminaram com `run_status = 0` (sucesso).
2. Para **todos** os eventos estendidos (`stop_xe.sql`).
3. Remove todos os arquivos do diretório de eventos (`/var/opt/mssql/log_jobs/xe`).
4. Reinicia **todos** os eventos estendidos (`start_xe.sql`).

| Item | Valor |
|---|---|
| Diretório de trabalho | `/var/opt/mssql/log_jobs/retention_xe/` |
| Diretório limpo | `/var/opt/mssql/log_jobs/xe` |
| Horário de referência da retenção | `06:40:00` |
| Agendamento | `40 6 */2 * *` — a cada 2 dias, às 06:40 |

---

## ✅ Pré-requisitos

- SQL Server em execução em **Amazon Linux 2**.
- `sqlcmd` disponível em `/opt/mssql-tools/bin/sqlcmd`.
- Usuário com permissão de escrita em `/var/opt/mssql/log_jobs/` e permissão de leitura/remoção em `/var/opt/mssql/log_jobs/xe`.
- Credencial SQL com acesso ao `msdb` (leitura de `sysjobs` / `sysjobhistory`) e permissão para `ALTER EVENT SESSION`.
- Acesso ao `crontab` do usuário que executa a rotina.
- Crie os arquivos `start_xe.sql` e `stop_xe.sql`, com o devido conteúdo disponibilizado no repositório, no diretório `/var/opt/mssql/log_jobs/retention_xe/`.

---

## 📁 Estrutura de Diretórios

```
/var/opt/mssql/log_jobs/
├── retention_xe/
│   ├── retention_xe.sh          # rotina principal
│   ├── run_retention_xe.sh      # wrapper com timestamp
│   ├── stop_xe.sql              # para todos os eventos estendidos
│   ├── start_xe.sql             # reinicia todos os eventos estendidos
│   ├── retention_xe.pid         # PID do processo (gerado em execução)
│   ├── stop_xe.log              # saída/erros do stop_xe.sql
│   ├── start_xe.log             # saída/erros do start_xe.sql
│   └── retention_xe.log         # log consolidado com timestamp
└── xe/                          # diretório dos arquivos .xel (alvo da limpeza)
```

---

## 🪜 Passo a Passo

### 1. Criar o diretório de trabalho

```bash
mkdir -p /var/opt/mssql/log_jobs/retention_xe
cd /var/opt/mssql/log_jobs/retention_xe
```

### 2. Criar o script principal e dar permissão de execução

```bash
touch retention_xe.sh
chmod +x retention_xe.sh
```

Cole o conteúdo de `retention.sh` (seção [Scripts](#-scripts)) e **ajuste as variáveis de conexão** (`server`, `username`, `password`).

### 3. Criar os arquivos SQL

```bash
touch stop_xe.sql
touch start_xe.sql
```

Cole o conteúdo correspondente em cada arquivo e **ajuste o cliente do evento `page_split`** conforme o ambiente.

### 4. Executar a rotina manualmente

```bash
cd /var/opt/mssql/log_jobs/retention_xe/
./retention_xe.sh
```

> ⚠️ O arquivo de origem referencia o comando `./retention.sh`; o script criado no passo 2 chama-se `retention_xe.sh`. Use o nome do arquivo que você efetivamente criou.

### 5. Verificar os arquivos de log gerados

```bash
ls -l /var/opt/mssql/log_jobs/retention_xe/
cat /var/opt/mssql/log_jobs/retention_xe/stop_xe.log
cat /var/opt/mssql/log_jobs/retention_xe/start_xe.log
```

- `retention_xe.pid` — ID do processo Linux da execução.
- `stop_xe.log` — possíveis mensagens de erro do comando SQL que para todos os eventos.
- `start_xe.log` — possíveis mensagens de erro do comando SQL que inicializa todos os eventos.

### 6. Criar o wrapper de execução com timestamp

```bash
touch run_retention_xe.sh
chmod +x run_retention_xe.sh
```

Cole o conteúdo de `run_retention_xe.sh` (seção [Scripts](#-scripts)).

### 7. Configurar o agendamento no `cron`

```bash
crontab -e
```

Adicione a entrada:

```cron
# A cada 2 dias às 06:40
# Processo de retenção de arquivos .xel das rotinas de monitoramento
40 6 */2 * * /var/opt/mssql/log_jobs/retention_xe/run_retention_xe.sh
```

### 8. Listar e validar o agendamento

```bash
crontab -l
```

---

## 📜 Scripts

### `retention_xe.sh`

```bash
#!/bin/bash

# Salve o PID do processo atual em um arquivo
echo $$ > /var/opt/mssql/log_jobs/retention_xe/retention_xe.pid

# Definições de conexão SQL Server
server="YOUR_SERVER"
username="YOUR_USER"
password='YOUR_PASSWORD'

echo "Validando execução de Jobs..."

#################################################
# Consulta as últimas execuções de jobs
# Se todas foram com sucesso continua o processo
sql_contabiliza_falha="SET NOCOUNT ON
;WITH cteJob
AS
(
SELECT
MAX(ISNULL([sjh].[instance_id], '')) AS [instance_id],
[sj].[job_id],
[sj].[name],
[sj].[enabled]
FROM [msdb]..[sysjobs] AS [sj]
LEFT JOIN [msdb]..[sysjobhistory] AS [sjh]
ON [sjh].[job_id] = [sj].[job_id]
AND [sjh].[step_id] = 0
WHERE [sj].[name] LIKE '%Collect%'
GROUP BY [sj].[job_id],
[sj].[name],
[sj].[enabled]
)

SELECT
[h].[run_status] AS UltimaExec
, COUNT(*) AS totalRunStatus
FROM [cteJob] AS [j]
LEFT JOIN [msdb].[dbo].[sysjobhistory] AS [h]
ON [j].[instance_id] = [h].[instance_id]
AND [h].[step_id] = 0
WHERE [h].[run_status] = 0
GROUP BY [h].[run_status]"

# Executa a instrução com o sqlcmd e atribui para uma variável
result_contabiliza_falha=$(/opt/mssql-tools/bin/sqlcmd -S $server -U $username -P $password -h-1 -Q "$sql_contabiliza_falha")

# Verifica se houve algum erro durante a execução da consulta
if [ $? -ne 0 ]; then
echo "Ocorreu um erro ao consultar as últimas execuções de jobs."
exit 1
fi

# Se resultado diferente de vazio não executa o restante da rotina
# ou seja, contabilizou falhas
if [ -n "$result_contabiliza_falha" ]; then
echo "Últimas execuções de Jobs tiveram falhas."
exit 1
fi

echo "Últimas execuções de todas as Jobs ocorreram com sucesso!"

echo "Parando eventos extendidos..."


#######################################
# Query para dar "STOP" nos eventos
# Caminho para o arquivo SQL
file_sql_query_stop_xe="/var/opt/mssql/log_jobs/retention_xe/stop_xe.sql"

# Executa a instrução com o sqlcmd
/opt/mssql-tools/bin/sqlcmd -S "$server" -U "$username" -P "$password" -i "$file_sql_query_stop_xe" > /var/opt/mssql/log_jobs/retention_xe/stop_xe.log 2>&1

# Verifica se houve algum erro durante a execução da consulta
if [ $? -ne 0 ]; then
echo "Ocorreu um erro ao parar os eventos extendidos."
exit 1
fi

echo "Eventos extendidos parados com sucesso!"


#######################################
# Diretório a ser limpo
dir="/var/opt/mssql/log_jobs/xe"

echo "Removendo arquivos do diretório $dir..."

# Remove todos os arquivos do diretório especificado
rm -rf "$dir"/*

# Verifica se a remoção foi bem-sucedida
if [ $? -eq 0 ]; then
echo "Arquivos removidos com sucesso do diretório $dir."
else
echo "Ocorreu um erro ao remover os arquivos do diretório $dir."
exit 1
fi

echo "Inicializando eventos extendidos..."


#######################################
# Query para dar "START" nos eventos
# Caminho para o arquivo SQL
file_sql_query_start_xe="/var/opt/mssql/log_jobs/retention_xe/start_xe.sql"

# Executa a instrução com o sqlcmd
/opt/mssql-tools/bin/sqlcmd -S "$server" -U "$username" -P "$password" -i "$file_sql_query_start_xe" > /var/opt/mssql/log_jobs/retention_xe/start_xe.log 2>&1

# Verifica se houve algum erro durante a execução da consulta
if [ $? -ne 0 ]; then
echo "Ocorreu um erro ao inicializar os eventos extendidos."
exit 1
fi

echo "Eventos extendidos inicializados com sucesso!"
```

### `run_retention_xe.sh`

```bash
#!/bin/bash

# Executa o script original e redireciona a saída (stdout e stderr)
# para adicionar timestamps
/var/opt/mssql/log_jobs/retention_xe/retention_xe.sh 2>&1 | while IFS= read -r line; do
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"
done >> /var/opt/mssql/log_jobs/retention_xe/retention_xe.log
```

### `stop_xe.sql`

```sql
-- Para todos os eventos estendidos
-- Ajuste o cliente do evento "page_split" conforme o ambiente
```

### `start_xe.sql`

```sql
-- Reinicia todos os eventos estendidos
-- Ajuste o cliente do evento "page_split" conforme o ambiente
```

> ⚠️ O conteúdo de `stop_xe.sql` e `start_xe.sql` não está nesse README. Os blocos acima são apenas marcadores de posição — preencha com o conteúdo real dos arquivos salvos nesse repositório como `stop_xe.sql` e `start_xe.sql`.

---

## ⏰ Automação via `cron`

```bash
# Criar o wrapper e dar permissão de execução
touch /var/opt/mssql/log_jobs/retention_xe/run_retention_xe.sh
chmod +x /var/opt/mssql/log_jobs/retention_xe/run_retention_xe.sh

# Abrir o crontab para edição
crontab -e
```

Entrada recomendada (com log consolidado via wrapper):

```cron
# A cada 2 dias às 06:40
# Processo de retenção de arquivos .xel das rotinas de monitoramento
40 6 */2 * * /var/opt/mssql/log_jobs/retention_xe/run_retention_xe.sh
```

Alternativa — log direto, sem wrapper:

```cron
40 6 */2 * * /var/opt/mssql/log_jobs/retention_xe/retention_xe.sh >> /var/opt/mssql/log_jobs/retention_xe/retention_xe.log 2>&1
```

Verificar e editar:

```bash
crontab -l   # lista as entradas atuais
crontab -e   # edita (mesma lógica do vim)
```

---

## 📋 Logs e Artefatos Gerados

| Arquivo | Papel |
|---|---|
| `retention_xe.pid` | PID do processo Linux da execução corrente |
| `stop_xe.log` | Saída e erros do `sqlcmd` ao executar `stop_xe.sql` |
| `start_xe.log` | Saída e erros do `sqlcmd` ao executar `start_xe.sql` |
| `retention_xe.log` | Log consolidado, com timestamp por linha (gerado pelo wrapper) |

---

## 🧠 Lógica de Guarda

A rotina **não apaga nada** se qualquer uma destas condições ocorrer:

1. **Falha na consulta** — se o `sqlcmd` retornar código diferente de `0` ao consultar o `msdb`, o script sai com `exit 1`.
2. **Job `%Collect%` com falha** — a consulta retorna linhas apenas quando existe `run_status = 0` registrado. Se o resultado **não for vazio**, significa que houve contabilização de falhas e o script aborta com `exit 1`.

Ou seja: a limpeza só acontece quando **todas** as últimas execuções dos jobs `%Collect%` foram bem-sucedidas. Isso evita apagar `.xel` que ainda podem ser necessários para diagnóstico de uma falha em andamento.

---

## 🛠️ Solução de Problemas

| Sintoma | Causa provável | Ação |
|---|---|---|
| `sqlcmd: command not found` | Caminho incorreto ou pacote ausente | Verificar `/opt/mssql-tools/bin/sqlcmd`; ajustar o caminho no script |
| `Permission denied` ao executar | Falta de bit de execução | `chmod +x retention_xe.sh run_retention_xe.sh` |
| `No such file or directory` | Diretório não criado | `mkdir -p /var/opt/mssql/log_jobs/retention_xe` |
| Nenhum `.xel` removido | Diretório `/var/opt/mssql/log_jobs/xe` vazio ou caminho errado | Conferir o caminho e o conteúdo do diretório |
| Rotina não dispara | Entrada de cron ausente ou incorreta | `crontab -l` e verificar logs do sistema |
| Rotina dispara mas falha | Job `%Collect%` com falha ou erro de conexão | Ler `retention_xe.log`, `stop_xe.log` e `start_xe.log` |

---

## 📌 Observações

- O horário `06:40:00` é uma **posição de referência**, não uma regra imutável — ajuste conforme a janela de manutenção do ambiente.
- `rm -rf "$dir"/*` remove **todos** os arquivos do diretório, sem filtro por extensão ou idade. Confirme que `/var/opt/mssql/log_jobs/xe` contém apenas artefatos descartáveis.
- O wrapper `run_retention_xe.sh` usa `>>` (append), portanto o `retention_xe.log` cresce indefinidamente. Considere rotação de log.
- O `retention_xe.pid` é sobrescrito a cada execução e não é usado para controle de concorrência — duas execuções simultâneas não são bloqueadas.

---

## 📚 Referências

- [Microsoft Learn — Extended Events](https://learn.microsoft.com/sql/relational-databases/extended-events/extended-events)
- [Microsoft Learn — ALTER EVENT SESSION](https://learn.microsoft.com/sql/t-sql/statements/alter-event-session-transact-sql)
- [Microsoft Learn — sqlcmd utility](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility)
- [Microsoft Learn — sysjobhistory (Transact-SQL)](https://learn.microsoft.com/sql/relational-databases/system-tables/dbo-sysjobhistory-transact-sql)
- [crontab(5) — Linux man page](https://man7.org/linux/man-pages/man5/crontab.5.html)

