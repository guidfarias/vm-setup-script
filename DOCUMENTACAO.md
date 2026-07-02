# Solução de Backup — RunCloud / CIPNET

> Backup de servidores RunCloud para o Amazon S3 em duas camadas complementares
> (Restic incremental + arquivos `.tar.gz` baixáveis), com instalação automatizada.

---

## 1. Visão Geral

Esta solução implementa **duas camadas complementares** de backup, armazenando tudo no Amazon S3. O objetivo é garantir recuperação rápida em qualquer cenário: desde a restauração de um único arquivo até a reconstrução completa do servidor.

### 1.1 — As duas camadas de backup

| Camada 1 — Restic (incremental) | Camada 2 — Baixáveis (`.tar.gz`) |
|---|---|
| Backup do `/home` completo | Um `.tar.gz` por aplicação (webapps) |
| Criptografado e deduplicado | Um `.tar.gz` com todos os dumps de banco |
| Incremental: só envia o que mudou | Baixáveis diretamente pelo painel AWS |
| Roda de segunda a sexta às 02:30 | Roda toda sexta-feira às 02:30 |
| Retenção: 7 diários / 2 semanais / 2 mensais | Expiração automática após 30 dias (lifecycle S3) |

### 1.2 — Estrutura no bucket S3

As duas camadas ficam em prefixos separados dentro do mesmo bucket, evitando conflito entre os arquivos internos do Restic e os `.tar.gz` baixáveis:

```
runcloud-cipnet/
│
├── Restic/
│   └── RunCloud-Teste-Duo/          ← repositório interno do Restic
│       ├── config                   ← configurações e chave de criptografia
│       ├── data/                    ← blocos deduplicados dos backups
│       ├── index/                   ← índice de busca
│       ├── keys/                    ← chaves de acesso
│       └── locks/                   ← controle de execução simultânea
│
└── Snapshots/
    └── RunCloud-Teste-Duo/
        └── 2026-06-29/              ← data do backup (gerado toda sexta)
            ├── databases-all.tar.gz ← dump de todos os bancos
            ├── runclouduser-site1.tar.gz
            └── runclouduser-site2.tar.gz
```

---

## 2. Instalação automatizada (recomendado)

> A instalação manual (Seção 6) continua documentada como referência, mas o
> caminho recomendado é o instalador, que faz **todos** os passos de uma vez e é
> **idempotente** (pode ser executado novamente com segurança).

O script `instalar_backup.sh` executa automaticamente:

1. Instala dependências do sistema (`mysql-client`, `gzip`, `tar`, `bzip2`, `unzip`, `curl`)
2. Instala o **AWS CLI v2** (instalador oficial, detecta x86_64/arm64)
3. Instala o **restic 0.17.3** (versão fixada e testada)
4. Baixa o `restic-backup.sh` para `/usr/local/bin/` e valida a sintaxe
5. Cria `/etc/restic/env` a partir de um template — **nunca sobrescreve** um `env` já existente
6. Configura o cron em `/etc/cron.d/restic-backup` (seg–sex às 02:30)
7. Aplica a **regra de lifecycle no S3** (expira os `.tar.gz` após 30 dias)
8. (Opcional) Roda o primeiro backup de teste

### Passo a passo

**1) Baixar e executar o instalador (como root):**

```bash
curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/instalar_backup.sh -o /tmp/instalar_backup.sh
sudo bash /tmp/instalar_backup.sh
```

Na primeira execução, o instalador cria o template `/etc/restic/env` e **para de forma segura** antes de aplicar o lifecycle e o primeiro backup (porque ainda não há credenciais reais).

**2) Preencher as credenciais reais:**

```bash
sudo nano /etc/restic/env
```

> ⚠️ **Regra de aspas — importante:** o arquivo é lido com `source` sob `set -u`.
> Use **aspas simples** em senhas (protege `$`, `*`, espaço). Ver Seção 3.1.

**3) Executar o instalador novamente** — agora ele detecta as credenciais, aplica o lifecycle S3 e oferece rodar o primeiro backup:

```bash
sudo bash /tmp/instalar_backup.sh
```

Pronto. A partir daqui o cron cuida de tudo.

### Opções do instalador

| Flag | Efeito |
|---|---|
| _(nenhuma)_ | Instala tudo e **pergunta** se roda o primeiro backup |
| `--run-now` | Roda o primeiro backup automaticamente (sem perguntar) |
| `--skip-run` | Não roda o primeiro backup |
| `--no-lifecycle` | Não aplica a regra de lifecycle no S3 |
| `--help` | Mostra a ajuda |

---

## 3. Configuração — `/etc/restic/env`

Todas as configurações ficam centralizadas neste arquivo, lido pelo script a cada execução. O instalador cria o template automaticamente; esta seção documenta cada variável.

### 3.1 — ⚠️ Regra de aspas (leia antes de editar)

O script faz `source /etc/restic/env` com `set -u`. Isso tem duas consequências:

- **Senhas → aspas simples `' '`.** Um `$` dentro de aspas duplas seria interpretado como variável e **quebraria o backup** (ou mudaria a senha silenciosamente).
  ```bash
  RESTIC_PASSWORD='ab$cd*ef'     # CERTO
  RESTIC_PASSWORD="ab$cd*ef"     # ERRADO — $cd vira variável!
  ```
- **Valores com `$(...)` que você QUER expandir → aspas duplas.**
  ```bash
  S3_PREFIX="$(hostname -s)"     # CERTO — queremos o hostname
  ```

### 3.2 — Permissões (obrigatórias)

O arquivo contém a senha do root do banco e a `RESTIC_PASSWORD`. **O script recusa rodar** se as permissões estiverem inseguras:

```bash
chmod 600 /etc/restic/env
chown root:root /etc/restic/env
```

### 3.3 — Conteúdo e variáveis

```bash
AWS_ACCESS_KEY_ID='SUA_ACCESS_KEY'
AWS_SECRET_ACCESS_KEY='SUA_SECRET_KEY'
AWS_DEFAULT_REGION='sa-east-1'

S3_BUCKET='runcloud-cipnet'
S3_PREFIX="$(hostname -s)"
RESTIC_S3_PREFIX="Restic/$(hostname -s)"
RESTIC_PASSWORD='SUA_SENHA_RESTIC_FORTE'

BACKUP_SOURCE='/home'
DB_DUMP_DIR='/home/backups/db'

MYSQL_USER='root'
MYSQL_PASSWORD='SENHA_ROOT_DO_BANCO_AQUI'
MYSQL_HOST='localhost'

KEEP_DAILY='7'
KEEP_WEEKLY='2'
KEEP_MONTHLY='2'

ENABLE_WEEKLY_ARCHIVES='true'
ARCHIVE_DAY='5'
ARCHIVE_S3_PREFIX='Snapshots'
ARCHIVE_KEEP_WEEKS='4'

CHECK_DAY='1'
CHECK_DATA_SUBSET='10%'

MIN_FREE_MB='2048'
LOG_FILE='/var/log/restic-backup.log'

# HEALTHCHECK_URL='https://hc-ping.com/SEU-UUID'
```

| Variável | Descrição |
|---|---|
| `AWS_ACCESS_KEY_ID` | Credencial de acesso AWS |
| `AWS_SECRET_ACCESS_KEY` | Chave secreta AWS |
| `AWS_DEFAULT_REGION` | Região do bucket (ex.: `sa-east-1`) |
| `S3_BUCKET` | Nome do bucket S3 |
| `S3_PREFIX` | Nome do servidor (hostname). Usado nos `Snapshots/` |
| `RESTIC_S3_PREFIX` | Prefixo do repositório Restic no S3 (`Restic/<hostname>`) |
| `RESTIC_PASSWORD` | Senha de criptografia do repositório Restic. **Não perca esta senha** (ver Seção 3.4) |
| `BACKUP_SOURCE` | Diretório raiz versionado pelo Restic (padrão `/home`) |
| `DB_DUMP_DIR` | Pasta local onde os dumps MySQL são gerados antes do backup |
| `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_HOST` | Credenciais do MySQL (passadas via arquivo temporário — **não** aparecem no `ps aux`) |
| `KEEP_DAILY` / `WEEKLY` / `MONTHLY` | Retenção do Restic: quantos backups manter por período |
| `ENABLE_WEEKLY_ARCHIVES` | Liga/desliga a geração dos `.tar.gz` baixáveis |
| `ARCHIVE_DAY` | Dia da semana para gerar os `.tar.gz` (`5` = sexta) |
| `ARCHIVE_S3_PREFIX` | Prefixo dos baixáveis no S3 (`Snapshots`) |
| `ARCHIVE_KEEP_WEEKS` | **Apenas referência** — a expiração real é feita pelo lifecycle S3 |
| `CHECK_DAY` | Dia da semana do check de integridade (`1` = segunda). Use um dia útil — o cron roda apenas seg-sex |
| `CHECK_DATA_SUBSET` | Quanto ler no check. Aceita tamanho (`5G`) ou percentual (`10%`). **Percentual escala com o repositório** |
| `MIN_FREE_MB` | Espaço livre mínimo (MB) exigido em `DB_DUMP_DIR` antes de dumpar (padrão `2048`) |
| `LOG_FILE` | Arquivo de log (rotacionado automaticamente) |
| `HEALTHCHECK_URL` | (Opcional) URL de monitoramento — sinaliza início/sucesso/falha |

### 3.4 — ⚠️ Recuperação de desastre

A `RESTIC_PASSWORD` é a **única** forma de ler os backups Restic. Se o servidor for perdido/reprovisionado e você não tiver essa senha guardada **fora do servidor** (gerenciador de senhas, cofre), **todos os backups Restic ficam irrecuperáveis**. O mesmo vale para as chaves AWS. **Guarde-as em outro lugar.**

---

## 4. Como o script funciona (comportamento)

A cada execução o `restic-backup.sh`:

1. Carrega e **valida** o `/etc/restic/env` (recusa rodar se as permissões forem inseguras).
2. **Impede execução simultânea** via lock (`flock`) — se outro backup estiver rodando, aborta.
3. **Testa a conexão MySQL antes** de apagar dumps antigos (se o banco estiver inacessível, os dumps antigos são preservados).
4. Verifica **espaço livre em disco** antes de dumpar.
5. Gera os dumps `.sql.gz` (com `--single-transaction`, sem travar o banco).
6. Faz o **snapshot incremental** do `/home` com o Restic.
7. Às sextas (ou com `FORCE_ARCHIVE=true`), gera os **`.tar.gz` por aplicação** e envia ao S3.
8. Aplica a **retenção** do Restic (`forget --prune`).
9. No dia configurado, roda o **check de integridade**.

> **Retenção dos baixáveis:** o script **não** apaga os `.tar.gz` — isso é feito pela
> **regra de lifecycle no S3** (aplicada pelo instalador), que expira o prefixo
> `Snapshots/` após 30 dias.

---

## 5. Operação

### 5.1 — Acompanhar execução

```bash
# Log principal do script
tail -f /var/log/restic-backup.log

# Log do cron (stdout/stderr da execução agendada)
tail -f /var/log/restic-cron.log
```

### 5.2 — Rodar comandos do restic (via `rr`)

O comando `restic` sozinho **não** sabe onde fica o repositório nem a senha — essas
informações estão no `/etc/restic/env`. Para não precisar exportar as variáveis à mão
toda vez, o instalador disponibiliza o wrapper **`rr`**, que carrega o `env`
automaticamente e repassa tudo ao `restic`:

```bash
rr snapshots                                   # listar snapshots
rr stats                                        # tamanho/estatísticas do repositório
rr check --read-data-subset=10%                 # verificar integridade
rr restore latest --target /tmp/restauracao     # restaurar (ver Seção 6)
rr help                                          # ajuda completa do restic
```

> Basicamente: onde a documentação disser `restic <algo>`, você pode digitar `rr <algo>`.

<details>
<summary>Alternativa sem o <code>rr</code> (exportar as variáveis manualmente)</summary>

```bash
source /etc/restic/env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION RESTIC_PASSWORD
export RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/${RESTIC_S3_PREFIX}"

restic snapshots
```
</details>

### 5.3 — Ver baixáveis no S3

```bash
source /etc/restic/env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

aws s3 ls "s3://${S3_BUCKET}/Snapshots/${S3_PREFIX}/" \
  --recursive --human-readable --summarize \
  --region "${AWS_DEFAULT_REGION}"
```

### 5.4 — Forçar backup manualmente

```bash
# Backup Restic + baixáveis (modo completo, independente do dia da semana)
FORCE_ARCHIVE=true /usr/local/bin/restic-backup.sh

# Apenas backup Restic (sem gerar .tar.gz)
/usr/local/bin/restic-backup.sh

# Simular (dry-run) — não envia nada ao S3
/usr/local/bin/restic-backup.sh --dry-run

# Forçar o check de integridade agora
/usr/local/bin/restic-backup.sh --check
```

### 5.5 — Testar a restauração (recomendado periodicamente)

> Um backup só é confiável se a restauração foi testada. O script tem um modo
> dedicado que restaura uma amostra em diretório temporário e valida a integridade,
> **sem alterar** o repositório nem o `/home`.

```bash
/usr/local/bin/restic-backup.sh --test-restore
```

### 5.6 — Verificar se o backup está rodando

```bash
ps aux | grep -E 'restic-backup|restic|aws s3 cp|tar -czf' | grep -v grep
```

---

## 6. Restauração

> ⚠️ **Atenção:** sempre restaure em um diretório temporário (`/tmp/restauracao`)
> antes de sobrescrever dados de produção. Verifique o conteúdo antes de mover.

### 6.1 — Preparar o ambiente

Com o wrapper `rr` (recomendado), **não é preciso preparar nada** — ele carrega as
variáveis sozinho. Basta usar `rr` no lugar de `restic` nos comandos abaixo.

<details>
<summary>Sem o <code>rr</code>: exporte as variáveis primeiro</summary>

```bash
source /etc/restic/env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION RESTIC_PASSWORD
export RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/${RESTIC_S3_PREFIX}"
```
</details>

### 6.2 — Restaurar via Restic

```bash
# Listar snapshots (anote o ID desejado)
rr snapshots

# Restaurar o snapshot mais recente (completo)
mkdir -p /tmp/restauracao
rr restore latest --target /tmp/restauracao

# Restaurar um snapshot específico (troque o ID)
rr restore 96b8f253 --target /tmp/restauracao

# Restaurar apenas um site específico
rr restore latest \
  --include '/home/runclouduser/webapps/meu-site' \
  --target /tmp/restauracao

# Restaurar diretamente no lugar original (SOBRESCREVE sem confirmação!)
rr restore latest --target /
```

### 6.3 — Restaurar um banco de dados

```bash
# A partir de um dump restaurado
zcat /tmp/restauracao/home/backups/db/NOME_DO_BANCO.sql.gz | mysql -u root NOME_DO_BANCO
```

### 6.4 — Restaurar a partir de um `.tar.gz` baixável

```bash
# Baixar do S3
aws s3 cp "s3://runcloud-cipnet/Snapshots/SERVIDOR/DATA/runclouduser-site1.tar.gz" /tmp/ \
  --region sa-east-1

# Descompactar
tar -xzf /tmp/runclouduser-site1.tar.gz -C /tmp/restauracao
```

### 6.5 — Verificar integridade do repositório

```bash
rr check                          # estrutural rápido (segundos)
rr check --read-data-subset=10%   # lê 10% dos dados (mais lento)
rr check --read-data              # tudo (muito lento em repos grandes)
```

---

## 7. Pré-requisitos técnicos (referência)

O instalador cuida de tudo abaixo automaticamente. Esta seção serve como referência.

### 7.1 — Versões

- **restic 0.17.3** — a versão via `apt` é muito antiga (0.8.x) e não suporta flags usadas no script. O instalador baixa o binário oficial fixado.
- **AWS CLI v2** — não disponível via `apt` no Ubuntu 24.04; o instalador usa o instalador oficial da AWS.

### 7.2 — Permissões IAM necessárias no bucket S3

| Permissão | Uso |
|---|---|
| `s3:PutObject` | Gravar arquivos no bucket |
| `s3:GetObject` | Ler arquivos (restauração) |
| `s3:DeleteObject` | Apagar durante o `forget`/`prune` do Restic |
| `s3:ListBucket` | Listar objetos |
| `s3:GetBucketLocation` | Descobrir a região do bucket |
| `s3:PutLifecycleConfiguration` | Aplicar a regra de expiração dos baixáveis (usado pelo instalador) |

---

## 8. Instalação manual (alternativa ao instalador)

> Mantida como referência. Prefira o instalador automatizado (Seção 2).

<details>
<summary>Expandir passo a passo manual</summary>

### 8.1 — Dependências

```bash
apt update
apt install -y mysql-client gzip tar bzip2 unzip curl

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
aws --version
```

### 8.2 — restic 0.17.3

```bash
wget https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_linux_amd64.bz2
bunzip2 restic_0.17.3_linux_amd64.bz2
mv restic_0.17.3_linux_amd64 /usr/local/bin/restic
chmod +x /usr/local/bin/restic
restic version
```

### 8.3 — Arquivo de variáveis

```bash
mkdir -p /etc/restic
chmod 700 /etc/restic
nano /etc/restic/env        # conteúdo: ver Seção 3.3 (atenção às aspas — Seção 3.1)
chmod 600 /etc/restic/env
chown root:root /etc/restic/env
```

### 8.4 — Script de backup

```bash
curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/configura_backup.sh -o /usr/local/bin/restic-backup.sh
chmod +x /usr/local/bin/restic-backup.sh
bash -n /usr/local/bin/restic-backup.sh
```

### 8.5 — Cron (`/etc/cron.d/restic-backup`)

```bash
cat > /etc/cron.d/restic-backup << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
30 2 * * 1-5 root /usr/local/bin/restic-backup.sh >> /var/log/restic-cron.log 2>&1
EOF
chmod 644 /etc/cron.d/restic-backup
```

### 8.6 — Primeiro backup

```bash
FORCE_ARCHIVE=true /usr/local/bin/restic-backup.sh
```

### 8.7 — Lifecycle S3 (expiração dos baixáveis)

```bash
cat > /tmp/lifecycle.json << 'EOF'
{
  "Rules": [
    {
      "ID": "delete-snapshots-after-30-days",
      "Status": "Enabled",
      "Filter": { "Prefix": "Snapshots/" },
      "Expiration": { "Days": 30 }
    }
  ]
}
EOF

source /etc/restic/env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

aws s3api put-bucket-lifecycle-configuration \
  --bucket "${S3_BUCKET}" \
  --lifecycle-configuration file:///tmp/lifecycle.json \
  --region "${AWS_DEFAULT_REGION}"

# Confirmar
aws s3api get-bucket-lifecycle-configuration --bucket "${S3_BUCKET}" --region "${AWS_DEFAULT_REGION}"
```

</details>

---

## 9. Referência Rápida

| Ação | Comando |
|---|---|
| **Instalar tudo** (1x por servidor) | `sudo bash instalar_backup.sh` |
| Backup completo (Restic + baixáveis) | `FORCE_ARCHIVE=true /usr/local/bin/restic-backup.sh` |
| Backup Restic apenas (sem `.tar.gz`) | `/usr/local/bin/restic-backup.sh` |
| Simular backup (dry-run) | `/usr/local/bin/restic-backup.sh --dry-run` |
| **Testar restauração** | `/usr/local/bin/restic-backup.sh --test-restore` |
| Forçar check de integridade | `/usr/local/bin/restic-backup.sh --check` |
| Listar snapshots Restic | `rr snapshots` |
| Restaurar último snapshot | `rr restore latest --target /tmp/restauracao` |
| Restaurar snapshot específico | `rr restore <ID> --target /tmp/restauracao` |
| Restaurar webapp específica | `rr restore latest --include '/home/user/webapps/site' --target /tmp/restauracao` |
| Ver baixáveis no S3 | `aws s3 ls s3://runcloud-cipnet/Snapshots/SERVIDOR/ --recursive --human-readable` |
| Baixar um `.tar.gz` do S3 | `aws s3 cp s3://runcloud-cipnet/Snapshots/SERVIDOR/DATA/arquivo.tar.gz /tmp/` |
| Restaurar banco de dados | `zcat /tmp/restauracao/home/backups/db/banco.sql.gz \| mysql -u root banco` |
| Verificar integridade | `rr check --read-data-subset=10%` |
| Testar sintaxe do script | `bash -n /usr/local/bin/restic-backup.sh` |
| Ver log em tempo real | `tail -f /var/log/restic-backup.log` |
| Ver log do cron | `tail -f /var/log/restic-cron.log` |
| Ver processos rodando | `ps aux \| grep restic-backup \| grep -v grep` |
| Ver lifecycle S3 configurado | `aws s3api get-bucket-lifecycle-configuration --bucket runcloud-cipnet --region sa-east-1` |
