#!/bin/bash
# =============================================================================
# restic-backup-pg.sh — Backup de /var/www + PostgreSQL para S3 (restic + tar.gz)
# CIPNET — variante para servidores com sites em /var/www e banco PostgreSQL
#
# O que este script faz:
#   1. Carrega variáveis de /etc/restic/env (valida permissões 600/root)
#   2. Valida pré-requisitos (binários, credenciais, espaço em disco)
#   3. Faz dump de todos os bancos PostgreSQL em ${DB_DUMP_DIR}
#      - suporta MÚLTIPLOS clusters (PG_PORTS='5432 5433'): cada cluster vai
#        para ${DB_DUMP_DIR}/porta-<porta>/
#      - formato custom do pg_dump (-Fc): comprimido e restaurável seletivamente
#      - pg_dumpall --globals-only: roles, senhas e permissões (globals.sql.gz)
#      - autenticação: peer via sudo -u postgres (padrão) ou senha via
#        PGPASSFILE temporário — a senha NÃO vaza no `ps aux`
#   4. Faz backup incremental de /var/www + dumps com restic
#   5. Gera .tar.gz por site e envia ao S3 (dia configurável / FORCE_ARCHIVE)
#   6. Aplica retenção (forget --prune)
#   7. Executa check de integridade semanal
#   8. (Opcional) Testa restore de amostra: --test-restore
#
# Uso:
#   bash restic-backup-pg.sh                  # backup normal
#   bash restic-backup-pg.sh --dry-run        # simula, nada é enviado
#   bash restic-backup-pg.sh --check          # força check de integridade
#   bash restic-backup-pg.sh --test-restore   # testa restauração de amostra
#   FORCE_ARCHIVE=true bash restic-backup-pg.sh
#
# Restauração rápida (referência):
#   rr snapshots                                        # listar snapshots
#   rr restore latest --target /tmp/rest --include /var/backups/db
#   sudo -u postgres pg_restore -p PORTA --clean --if-exists -d BANCO \
#       /var/backups/db/porta-PORTA/BANCO.dump
#   gunzip -c porta-PORTA/globals.sql.gz | sudo -u postgres psql -p PORTA
#   (se o banco não existir: sudo -u postgres createdb -p PORTA BANCO)
#
# ⚠️  IMPORTANTE — RECUPERAÇÃO DE DESASTRE:
#   A RESTIC_PASSWORD é a ÚNICA forma de ler os backups restic. Se o servidor
#   for perdido/reprovisionado e você não tiver essa senha guardada EM OUTRO
#   LUGAR (gerenciador de senhas, cofre, etc.), TODOS os backups restic ficam
#   irrecuperáveis. Guarde-a fora do servidor. O mesmo vale para as chaves AWS.
#
# ⚠️  /etc/restic/env: use ASPAS SIMPLES nos valores com caracteres especiais
#   (ex.: RESTIC_PASSWORD='ab$cd') — o arquivo é carregado com `source` sob
#   set -u, e um `$` dentro de aspas duplas quebra ou corrompe a senha.
#   O arquivo deve ser chmod 600 e dono root.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO — defaults (sobrescritos pelo /etc/restic/env)
# ---------------------------------------------------------------------------

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Sem default proposital: cada frota define o bucket no /etc/restic/env.
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-$(hostname -s)}"
RESTIC_S3_PREFIX="${RESTIC_S3_PREFIX:-Restic/${S3_PREFIX}}"

RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"

# Diretório de origem do backup (permite testar sem tocar em /var/www real)
BACKUP_SOURCE="${BACKUP_SOURCE:-/var/www}"

# Fica FORA de /var/www de propósito (não aparece nos sites); o restic faz
# snapshot dele junto com o BACKUP_SOURCE (ver run_backup).
DB_DUMP_DIR="${DB_DUMP_DIR:-/var/backups/db}"

# --- PostgreSQL ---
# PG_PASSWORD vazio (padrão) → autenticação peer: comandos rodam como o
#   usuário de sistema ${PG_SYSTEM_USER} via sudo (funciona no Postgres
#   padrão de Debian/Ubuntu, sem configurar senha nenhuma).
# PG_PASSWORD definido → conecta via TCP em ${PG_HOST}:<porta> com
#   ${PG_USER}, senha entregue por PGPASSFILE temporário (não vaza no ps).
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-localhost}"
# Portas dos clusters a dumpar, separadas por espaço. Servidores com mais de
# um cluster (ex.: Postgres 14 e 16 lado a lado) listam todas: '5432 5433'.
# Descubra as portas com: pg_lsclusters
PG_PORTS="${PG_PORTS:-5432}"
PG_SYSTEM_USER="${PG_SYSTEM_USER:-postgres}"
# Diretório dos binários (pg_dump/psql/...). Vazio (padrão) → usa a versão
# MAIS NOVA em /usr/lib/postgresql/*/bin, com fallback para o PATH.
# Necessário porque o wrapper /usr/bin/pg_dump do Debian/Ubuntu escolhe a
# versão pelo cluster da porta 5432 — e um pg_dump antigo se RECUSA a dumpar
# um cluster mais novo. A versão mais nova dumpa todos.
PG_BIN_DIR="${PG_BIN_DIR:-}"
# Bancos ignorados no dump (regex ERE). Templates já são filtrados na query.
PG_EXCLUDE_REGEX="${PG_EXCLUDE_REGEX:-^(postgres)$}"

KEEP_DAILY="${KEEP_DAILY:-5}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-4}"

# Segunda-feira (o cron roda seg-sex; 0=domingo nunca executaria).
CHECK_DAY="${CHECK_DAY:-1}"
# Aceita valor fixo (ex.: 5G) ou percentual (ex.: 10%). Percentual escala com o repo.
CHECK_DATA_SUBSET="${CHECK_DATA_SUBSET:-10%}"

# Espaço livre mínimo (em MB) exigido em DB_DUMP_DIR antes de dumpar os bancos.
MIN_FREE_MB="${MIN_FREE_MB:-2048}"

LOG_FILE="${LOG_FILE:-/var/log/restic-backup.log}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"

# Lock para evitar duas execuções simultâneas (cron sobreposto).
LOCK_FILE="${LOCK_FILE:-/var/run/restic-backup.lock}"

DRY_RUN=false
FORCE_CHECK=false
TEST_RESTORE=false

ENABLE_WEEKLY_ARCHIVES="${ENABLE_WEEKLY_ARCHIVES:-true}"
ARCHIVE_DAY="${ARCHIVE_DAY:-5}"
ARCHIVE_S3_PREFIX="${ARCHIVE_S3_PREFIX:-Snapshots}"
ARCHIVE_KEEP_WEEKS="${ARCHIVE_KEEP_WEEKS:-1}"

# ---------------------------------------------------------------------------
# ALERTAS (opcional) — Healthchecks.io (dead man's switch)
# ---------------------------------------------------------------------------
# Defina HEALTHCHECK_URL no /etc/restic/env para ativar. Deixe vazio p/ desligar.
# O script sinaliza início (/start), sucesso e falha (/fail) automaticamente.
# É a forma mais confiável de descobrir que o backup PAROU de rodar.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# ---------------------------------------------------------------------------
# STATUS PARA MONITORAMENTO (JSON gravado no S3 em Monitoramento/<host>.json)
# ---------------------------------------------------------------------------
# Preenchido ao longo da execução e gravado SEMPRE no final (sucesso ou falha),
# inclusive em falha precoce. O MCP/painel lê esses JSONs para ver a frota sem
# conectar em servidor nenhum. Arquivo local de status (fallback / auditoria):
STATUS_LOCAL_FILE="${STATUS_LOCAL_FILE:-/var/log/restic-status.json}"
# Prefixo (pasta) no S3 onde os JSONs de status são gravados.
STATUS_S3_PREFIX="${STATUS_S3_PREFIX:-Monitoramento}"
STATUS_SCRIPT_VERSION="2026-07-pg"

STATUS_STARTED_AT=""          # ISO8601 do início
STATUS_DB_OK=0
STATUS_DB_FAIL=0
STATUS_ARCHIVE_RAN="false"
STATUS_ARCHIVE_APPS_OK=0
STATUS_ARCHIVE_APPS_FAIL=0
STATUS_SNAPSHOT_ID=""
STATUS_REPO_SIZE=""
STATUS_SNAPSHOTS_TOTAL=""
STATUS_CHECK_RAN="false"
STATUS_ERRORS=()              # array de mensagens de erro/aviso relevantes
STATUS_WRITTEN="false"        # evita escrever duas vezes

# Registra uma mensagem no array de erros do status (para o JSON).
status_add_error() {
    STATUS_ERRORS+=("$*")
}

# ---------------------------------------------------------------------------
# ESTADO INTERNO / LIMPEZA
# ---------------------------------------------------------------------------

EXCLUDE_FILE=""
PGPASS_FILE=""
PG_USE_SUDO=false
RESTORE_TEST_DIR=""

# Caminhos efetivos dos binários PostgreSQL (definidos por resolve_pg_bins).
PSQL_BIN="psql"
PG_DUMP_BIN="pg_dump"
PG_DUMPALL_BIN="pg_dumpall"
PG_RESTORE_BIN="pg_restore"

cleanup() {
    # Preserva o código de saída original: como este é o trap de EXIT, o status
    # do último comando aqui viraria o exit do script. `return 0` garante que
    # um backup bem-sucedido não seja reportado como falha ao cron.
    local exit_code=$?

    # Publica o status de monitoramento SEMPRE (sucesso, falha parcial ou falha
    # precoce). Classificação:
    #   - exit != 0                    → "error"   (abortou; ex.: restic ausente)
    #   - exit == 0 mas houve erros    → "partial" (ex.: 1 banco falhou no dump)
    #   - exit == 0 e sem erros        → "success"
    # write_status é no-op em dry-run/test-restore e nunca deixa o script falhar.
    local overall="success"
    if (( exit_code != 0 )); then
        overall="error"
    elif (( ${#STATUS_ERRORS[@]} > 0 )); then
        overall="partial"
    fi
    write_status "${overall}" || true

    [[ -n "${EXCLUDE_FILE}" ]]     && rm -f "${EXCLUDE_FILE}"
    [[ -n "${PGPASS_FILE}" ]]      && rm -f "${PGPASS_FILE}"
    [[ -n "${RESTORE_TEST_DIR}" ]] && rm -rf "${RESTORE_TEST_DIR}"
    return "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# FUNÇÕES DE LOG
# ---------------------------------------------------------------------------

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # Garante que o diretório do log exista antes do primeiro write. Se o log
    # não for gravável, ainda mostra no stdout/stderr (não deixa o backup mudo).
    local logdir
    logdir="$(dirname "${LOG_FILE}")"
    [[ -d "${logdir}" ]] || mkdir -p "${logdir}" 2>/dev/null || true
    if [[ -w "${logdir}" || -w "${LOG_FILE}" ]]; then
        echo "${ts} [${level}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo "${ts} [${level}] ${msg}"
    fi
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

die() {
    error "$@"
    status_add_error "$*"
    notify_failure "$*"
    exit 1
}

rotate_log() {
    if [[ -f "${LOG_FILE}" ]]; then
        local lines
        lines="$(wc -l < "${LOG_FILE}")"
        if (( lines > LOG_MAX_LINES )); then
            tail -n "${LOG_MAX_LINES}" "${LOG_FILE}" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# ALERTAS — helpers Healthchecks.io (no-op se HEALTHCHECK_URL vazio)
# ---------------------------------------------------------------------------

notify_start() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0
    command -v curl &>/dev/null || return 0
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}/start" &>/dev/null || true
}

notify_success() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0
    command -v curl &>/dev/null || return 0
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}" &>/dev/null || true
}

notify_failure() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0
    command -v curl &>/dev/null || return 0
    # Envia a mensagem de erro no corpo (aparece no painel do Healthchecks).
    curl -fsS -m 10 --retry 3 --data-raw "${1:-falha}" \
        "${HEALTHCHECK_URL}/fail" &>/dev/null || true
}

# ---------------------------------------------------------------------------
# ARGUMENTOS
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "${arg}" in
        --dry-run)      DRY_RUN=true ;;
        --check)        FORCE_CHECK=true ;;
        --test-restore) TEST_RESTORE=true ;;
        --help|-h)
            cat <<'HELP'
Uso:
  bash restic-backup-pg.sh                  # backup normal
  bash restic-backup-pg.sh --dry-run        # simula, nada é enviado ao S3
  bash restic-backup-pg.sh --check          # força check de integridade
  bash restic-backup-pg.sh --test-restore   # testa restauração de amostra e sai
  FORCE_ARCHIVE=true bash restic-backup-pg.sh
HELP
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: ${arg}" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# CARREGA VARIÁVEIS EXTERNAS (com verificação de segurança das permissões)
# ---------------------------------------------------------------------------

load_env_file() {
    if [[ ! -f "${RESTIC_ENV_FILE}" ]]; then
        warn "Arquivo ${RESTIC_ENV_FILE} não encontrado. Usando variáveis do ambiente."
        return 0
    fi

    # O env contém a senha do PostgreSQL (se usada) e a RESTIC_PASSWORD.
    # Recusa carregar se estiver legível por outros usuários.
    # Suporta stat do GNU (Linux, -c) e do BSD (macOS, -f).
    local perms owner
    perms="$(stat -c '%a' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Lp' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"
    owner="$(stat -c '%U' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Su' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"

    if [[ "${perms}" == "???" ]]; then
        warn "Não foi possível verificar permissões de ${RESTIC_ENV_FILE} (stat indisponível). Prosseguindo."
    elif [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        die "Permissões inseguras em ${RESTIC_ENV_FILE} (${perms}). Corrija com: chmod 600 ${RESTIC_ENV_FILE}"
    fi
    if [[ "${owner}" != "???" && "${owner}" != "root" && "${owner}" != "$(id -un)" ]]; then
        warn "Dono de ${RESTIC_ENV_FILE} é '${owner}' (esperado root)."
    fi

    # shellcheck source=/dev/null
    source "${RESTIC_ENV_FILE}"

    # Reaplica defaults para variáveis que o env pode ter deixado vazias.
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-sa-east-1}"
    CHECK_DATA_SUBSET="${CHECK_DATA_SUBSET:-10%}"

    info "Variáveis carregadas de ${RESTIC_ENV_FILE} (perms ${perms}, dono ${owner})"
}

# ---------------------------------------------------------------------------
# VALIDAÇÕES
# ---------------------------------------------------------------------------

require_cmd() {
    # require_cmd <binário> <dica de instalação>
    if ! command -v "$1" &>/dev/null; then
        error "'$1' não encontrado. ${2:-}"
        return 1
    fi
    return 0
}

# Define QUAL versão dos binários PostgreSQL usar (ver comentário em PG_BIN_DIR).
resolve_pg_bins() {
    if [[ -z "${PG_BIN_DIR}" ]]; then
        PG_BIN_DIR="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    fi
    if [[ -n "${PG_BIN_DIR}" && -x "${PG_BIN_DIR}/pg_dump" ]]; then
        PSQL_BIN="${PG_BIN_DIR}/psql"
        PG_DUMP_BIN="${PG_BIN_DIR}/pg_dump"
        PG_DUMPALL_BIN="${PG_BIN_DIR}/pg_dumpall"
        PG_RESTORE_BIN="${PG_BIN_DIR}/pg_restore"
        info "Binários PostgreSQL: ${PG_BIN_DIR} ($("${PG_DUMP_BIN}" --version 2>/dev/null | head -1))"
    else
        [[ -n "${PG_BIN_DIR}" ]] && warn "PG_BIN_DIR='${PG_BIN_DIR}' sem pg_dump executável — usando binários do PATH."
        PG_BIN_DIR=""
        info "Binários PostgreSQL: do PATH ($(pg_dump --version 2>/dev/null | head -1 || echo 'pg_dump ausente'))"
    fi
}

validate_env() {
    local errors=0

    require_cmd restic             "Instale o restic (https://restic.net)."  || errors=$((errors + 1))
    require_cmd "${PG_DUMP_BIN}"    "apt install postgresql-client -y"       || errors=$((errors + 1))
    require_cmd "${PG_DUMPALL_BIN}" "apt install postgresql-client -y"       || errors=$((errors + 1))
    require_cmd "${PG_RESTORE_BIN}" "apt install postgresql-client -y"       || errors=$((errors + 1))
    require_cmd "${PSQL_BIN}"       "apt install postgresql-client -y"       || errors=$((errors + 1))
    require_cmd gzip               "apt install gzip -y"                     || errors=$((errors + 1))

    if [[ -z "${AWS_ACCESS_KEY_ID}" ]]; then
        error "AWS_ACCESS_KEY_ID não definido."; errors=$((errors + 1))
    fi
    if [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
        error "AWS_SECRET_ACCESS_KEY não definido."; errors=$((errors + 1))
    fi
    if [[ -z "${RESTIC_PASSWORD}" ]]; then
        error "RESTIC_PASSWORD não definido."; errors=$((errors + 1))
    fi
    if [[ -z "${S3_BUCKET}" ]]; then
        error "S3_BUCKET não definido."; errors=$((errors + 1))
    fi
    if [[ ! -d "${BACKUP_SOURCE}" ]]; then
        error "Diretório de origem não existe: ${BACKUP_SOURCE}"; errors=$((errors + 1))
    fi

    (( errors == 0 )) || die "${errors} erro(s) de configuração encontrados. Abortando."
}

# Garante que só um backup rode por vez (evita corromper dumps entre execuções).
acquire_lock() {
    if ! command -v flock &>/dev/null; then
        warn "flock não encontrado (util-linux). Prosseguindo SEM proteção contra execução simultânea."
        return 0
    fi
    # Usa file descriptor 9 preso ao LOCK_FILE; flock não-bloqueante.
    exec 9>"${LOCK_FILE}" || die "Não foi possível abrir o lock ${LOCK_FILE}."
    if ! flock -n 9; then
        die "Outra execução do backup já está em andamento (lock: ${LOCK_FILE}). Abortando."
    fi
}

# ---------------------------------------------------------------------------
# EXPORTA VARIÁVEIS PARA O RESTIC
# ---------------------------------------------------------------------------

export_restic_env() {
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_DEFAULT_REGION
    export RESTIC_PASSWORD
    export RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/${RESTIC_S3_PREFIX}"
    export RESTIC_COMPRESSION="auto"
}

# ---------------------------------------------------------------------------
# AUTENTICAÇÃO POSTGRESQL
# ---------------------------------------------------------------------------
# Dois modos:
#   1. PG_PASSWORD definido → TCP em PG_HOST:<porta> como PG_USER; a senha vai
#      num PGPASSFILE temporário (chmod 600, apagado no cleanup) — nunca
#      aparece na linha de comando nem no `ps aux`.
#   2. PG_PASSWORD vazio (padrão) → autenticação peer: roda os comandos como o
#      usuário de sistema ${PG_SYSTEM_USER} via sudo. É o modo que funciona
#      "de fábrica" no PostgreSQL de Debian/Ubuntu, sem senha nenhuma.

setup_pg_auth() {
    if [[ -n "${PG_PASSWORD}" ]]; then
        PGPASS_FILE="$(mktemp)"
        chmod 600 "${PGPASS_FILE}"
        # Formato pgpass: host:porta:banco:usuario:senha — uma linha por porta.
        local port
        for port in ${PG_PORTS}; do
            printf '%s:%s:*:%s:%s\n' \
                "${PG_HOST}" "${port}" "${PG_USER}" "${PG_PASSWORD}"
        done > "${PGPASS_FILE}"
        export PGPASSFILE="${PGPASS_FILE}"
        export PGHOST="${PG_HOST}"
        export PGUSER="${PG_USER}"
        PG_USE_SUDO=false
        info "PostgreSQL: autenticação por senha (${PG_USER}@${PG_HOST}, portas ${PG_PORTS}, via PGPASSFILE)."
    elif [[ "$(id -u)" -eq 0 ]] && id -u "${PG_SYSTEM_USER}" &>/dev/null; then
        PG_USE_SUDO=true
        info "PostgreSQL: autenticação peer (sudo -u ${PG_SYSTEM_USER}, portas ${PG_PORTS})."
    else
        # Sem senha e sem como virar o usuário postgres: tenta como o usuário
        # atual mesmo (útil em testes locais); a conexão é validada adiante.
        PG_USE_SUDO=false
        warn "PostgreSQL: sem PG_PASSWORD e sem usuário '${PG_SYSTEM_USER}' — tentando como $(id -un)."
    fi
}

# Executa um comando do cliente PostgreSQL no modo de autenticação escolhido.
# No modo sudo, o redirecionamento de saída (> arquivo) continua sendo feito
# pelo root — os dumps ficam com dono root em DB_DUMP_DIR (chmod 700).
pg_exec() {
    if [[ "${PG_USE_SUDO}" == "true" ]]; then
        sudo -n -u "${PG_SYSTEM_USER}" "$@"
    else
        "$@"
    fi
}

# Wrappers: 1º argumento é a PORTA do cluster; -X ignora .psqlrc. A porta vai
# explícita em cada comando (o sudo não repassa variáveis PG* exportadas).
# Os *_BIN vêm de resolve_pg_bins (versão mais nova instalada).
psql_cmd()       { local p="$1"; shift; pg_exec "${PSQL_BIN}"       -X -p "${p}" "$@"; }
pg_dump_cmd()    { local p="$1"; shift; pg_exec "${PG_DUMP_BIN}"       -p "${p}" "$@"; }
pg_dumpall_cmd() { local p="$1"; shift; pg_exec "${PG_DUMPALL_BIN}"    -p "${p}" "$@"; }

# ---------------------------------------------------------------------------
# INICIALIZA REPOSITÓRIO (se necessário)
# ---------------------------------------------------------------------------

init_repo_if_needed() {
    if restic cat config &>/dev/null; then
        info "Repositório restic já existe em: ${RESTIC_REPOSITORY}"
        return 0
    fi

    info "Repositório não encontrado. Inicializando: ${RESTIC_REPOSITORY}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando inicialização do repositório."
        return 0
    fi

    restic init || die "Falha ao inicializar repositório restic."
    info "Repositório inicializado com sucesso."
}

# ---------------------------------------------------------------------------
# DUMP DOS BANCOS POSTGRESQL
# ---------------------------------------------------------------------------

check_disk_space() {
    # Verifica espaço livre no filesystem de DB_DUMP_DIR antes de dumpar.
    mkdir -p "${DB_DUMP_DIR}"
    local free_mb
    free_mb="$(df -Pm "${DB_DUMP_DIR}" | awk 'NR==2 {print $4}')"
    if [[ -n "${free_mb}" ]] && (( free_mb < MIN_FREE_MB )); then
        die "Espaço insuficiente em ${DB_DUMP_DIR}: ${free_mb}MB livres (< ${MIN_FREE_MB}MB exigidos)."
    fi
    info "Espaço livre em ${DB_DUMP_DIR}: ${free_mb}MB (mínimo ${MIN_FREE_MB}MB) OK."
}

# Dumpa UM cluster (porta) para ${DB_DUMP_DIR}/porta-<porta>/.
# Retorna 1 se o cluster estiver inacessível (dumps antigos dele preservados).
# Incrementa STATUS_DB_OK / STATUS_DB_FAIL diretamente.
dump_cluster() {
    local port="$1"
    local port_dir="${DB_DUMP_DIR}/porta-${port}"

    info "── Cluster porta ${port} ──"
    if ! psql_cmd "${port}" -Atqc "SELECT 1;" &>/dev/null; then
        error "Falha ao conectar no PostgreSQL na porta ${port}. Dumps antigos desse cluster preservados."
        status_add_error "conexão falhou: porta ${port}"
        return 1
    fi
    info "Conexão OK (porta ${port})."

    mkdir -p "${port_dir}"
    chmod 700 "${port_dir}"
    info "Limpando dumps antigos em ${port_dir}"
    find "${port_dir}" -type f \( -name "*.dump" -o -name "*.sql.gz" \) -delete

    # Globals: roles, senhas de usuários do banco, permissões e tablespaces.
    # Sem isso, restaurar um .dump em servidor novo falha nos OWNER/GRANT.
    info "Dumping globals (roles/permissões): porta-${port}/globals.sql.gz"
    set +e
    pg_dumpall_cmd "${port}" --globals-only 2>>"${LOG_FILE}" | gzip -9 > "${port_dir}/globals.sql.gz"
    local globals_rc=${PIPESTATUS[0]}
    set -e
    if (( globals_rc == 0 )); then
        chmod 600 "${port_dir}/globals.sql.gz"
    else
        error "Falha no dump dos globals da porta ${port} (rc=${globals_rc})"
        status_add_error "dump falhou: globals porta ${port} (rc=${globals_rc})"
        rm -f "${port_dir}/globals.sql.gz"
    fi

    # Lista bancos de usuário (templates ficam de fora na própria query).
    local db_list
    db_list="$(psql_cmd "${port}" -Atqc \
        "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;" \
        2>>"${LOG_FILE}" | grep -Ev "${PG_EXCLUDE_REGEX}" || true)"

    if [[ -z "${db_list}" ]]; then
        warn "Nenhum banco de usuário na porta ${port} (cluster vazio?)."
        return 0
    fi

    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue
        local dump_file="${port_dir}/${db}.dump"

        info "Dumping banco: ${db} (porta ${port})"

        # Formato custom (-Fc): já sai comprimido e restaura com pg_restore
        # (inclusive tabelas isoladas). Escreve via stdout para o arquivo ficar
        # com dono root mesmo quando o pg_dump roda como postgres (sudo).
        set +e
        pg_dump_cmd "${port}" --format=custom --compress=6 "${db}" \
            2>>"${LOG_FILE}" > "${dump_file}"
        local dump_rc=$?
        set -e

        if (( dump_rc == 0 )); then
            chmod 600 "${dump_file}"
            STATUS_DB_OK=$((STATUS_DB_OK + 1))
        else
            error "Falha no dump do banco: ${db} porta ${port} (rc=${dump_rc})"
            status_add_error "dump falhou: ${db} porta ${port} (rc=${dump_rc})"
            rm -f "${dump_file}"
            STATUS_DB_FAIL=$((STATUS_DB_FAIL + 1))
        fi
    done <<< "${db_list}"

    return 0
}

dump_databases() {
    info "Iniciando dump dos bancos PostgreSQL em ${DB_DUMP_DIR} (portas: ${PG_PORTS})"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando dump de bancos."
        return 0
    fi

    check_disk_space
    chmod 700 "${DB_DUMP_DIR}"

    local reachable=0 port
    for port in ${PG_PORTS}; do
        if dump_cluster "${port}"; then
            reachable=$((reachable + 1))
        fi
    done

    if (( reachable == 0 )); then
        die "Nenhum cluster PostgreSQL acessível (portas: ${PG_PORTS}). Dumps antigos preservados."
    fi

    # Remove resquícios de layout antigo/portas removidas da config: arquivos
    # soltos na raiz de DB_DUMP_DIR (os dumps atuais vivem em porta-<porta>/).
    find "${DB_DUMP_DIR}" -maxdepth 1 -type f \( -name "*.dump" -o -name "*.sql.gz" \) -delete

    info "Dump finalizado: ${STATUS_DB_OK} banco(s) OK, ${STATUS_DB_FAIL} falha(s)."

    if (( STATUS_DB_FAIL > 0 )); then
        warn "Alguns bancos falharam no dump. Backup do ${BACKUP_SOURCE} continuará, mas revise o log."
    fi
}

# ---------------------------------------------------------------------------
# ARQUIVO DE EXCLUSÕES
# ---------------------------------------------------------------------------
# NOTA: *.log e .git são excluídos do restic — se precisar do histórico git
# ou de logs para auditoria ao restaurar um site, remova as linhas.

build_exclude_file() {
    EXCLUDE_FILE="$(mktemp)"
    cat > "${EXCLUDE_FILE}" << 'EXCLUDES'
# Dependências e caches de projeto
node_modules
.npm
.composer/cache
.pip
__pycache__
*.pyc
*.pyo
.cache
.gradle
.m2
target

# Git e arquivos temporários
.git
*.tmp
*.swp
*.orig
~*
.DS_Store
Thumbs.db

# Logs e caches comuns
*.log
*/wp-content/cache/*
*/wp-content/upgrade/*
*/cache/*
*/tmp/*
*/storage/framework/cache/*
*/storage/framework/sessions/*
*/storage/framework/views/*
*/var/cache/*

# Arquivos de processo/sistema
*.sock
*.pid
swap
swapfile

# Lixeiras locais
.Trash
.trash

# Backups gerados por plugins WordPress (caso haja WP em /var/www)
*/wp-content/ai1wm-backups/*
*/wp-content/updraft/*
*/wp-content/backups-dup-lite/*
*/wp-content/backup-db/*
*/wp-content/wpvividbackups/*
EXCLUDES
}

# ---------------------------------------------------------------------------
# BACKUP DO /VAR/WWW + DUMPS
# ---------------------------------------------------------------------------

run_backup() {
    info "Iniciando backup restic de ${BACKUP_SOURCE} + ${DB_DUMP_DIR}"
    info "Repositório: ${RESTIC_REPOSITORY}"

    # DB_DUMP_DIR entra como segundo caminho do snapshot: diferente do layout
    # RunCloud (dumps dentro de /home), aqui os dumps ficam fora de /var/www.
    local restic_flags=(
        backup
        "${BACKUP_SOURCE}"
        "${DB_DUMP_DIR}"
        --exclude-file="${EXCLUDE_FILE}"
        --tag "host=$(hostname -s)"
        --tag "varwww"
        --tag "postgres"
        --tag "daily"
        --one-file-system
    )

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Simulando backup. Nada será enviado ao S3."
        restic "${restic_flags[@]}" --dry-run
        return 0
    fi

    restic "${restic_flags[@]}" || die "Snapshot restic falhou."
    info "Backup restic finalizado com sucesso."

    # Captura o ID do snapshot recém-criado (para o status). Falha aqui não é
    # crítica — é só metadado de monitoramento.
    STATUS_SNAPSHOT_ID="$(restic snapshots latest --json 2>/dev/null \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)"
}

# ---------------------------------------------------------------------------
# BACKUP SEMANAL — .tar.gz por site (dia configurável ou FORCE_ARCHIVE)
# ---------------------------------------------------------------------------

run_weekly_app_archives() {
    if [[ "${ENABLE_WEEKLY_ARCHIVES}" != "true" ]]; then
        info "Arquivos compactados semanais desativados (ENABLE_WEEKLY_ARCHIVES != true)."
        return 0
    fi

    local today_dow
    today_dow="$(date +%w)"

    if [[ "${today_dow}" != "${ARCHIVE_DAY}" ]] && [[ "${FORCE_ARCHIVE:-false}" != "true" ]]; then
        info "Backup compactado semanal pulado. Configurado para o dia ${ARCHIVE_DAY} (hoje: ${today_dow})."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando geração dos compactados semanais."
        return 0
    fi

    require_cmd aws "apt install awscli -y (ou use o instalador oficial da AWS)." || {
        warn "aws cli não encontrado. Pulando compactados semanais."
        return 0
    }

    STATUS_ARCHIVE_RAN="true"

    local today base_s3_path
    today="$(date '+%Y-%m-%d')"
    base_s3_path="s3://${S3_BUCKET}/${ARCHIVE_S3_PREFIX}/${S3_PREFIX}/${today}"

    info "Iniciando backup compactado semanal por site."
    info "Destino S3: ${base_s3_path}"

    # Dumps dos bancos.
    if [[ -d "${DB_DUMP_DIR}" ]]; then
        info "Gerando arquivo compactado dos dumps dos bancos."
        set +e
        tar -czf - -C "$(dirname "${DB_DUMP_DIR}")" "$(basename "${DB_DUMP_DIR}")" 2>>"${LOG_FILE}" \
            | aws s3 cp - "${base_s3_path}/databases-all.tar.gz" \
                --region "${AWS_DEFAULT_REGION}" >>"${LOG_FILE}" 2>&1
        # Captura o array inteiro de uma vez: qualquer atribuição intermediária
        # (ex.: `local x=${PIPESTATUS[0]}`) reseta PIPESTATUS.
        local rc=("${PIPESTATUS[@]}")
        set -e
        if (( rc[0] != 0 || rc[1] != 0 )); then
            warn "Falha ao gerar/enviar databases-all.tar.gz (tar=${rc[0]}, aws=${rc[1]})."
        fi
    else
        warn "Diretório de dumps não encontrado: ${DB_DUMP_DIR}"
    fi

    # Sites: um diretório por site direto em /var/www/<site>
    local app_count=0 fail_count=0
    while IFS= read -r app_path; do
        [[ -z "${app_path}" ]] && continue
        [[ ! -d "${app_path}" ]] && continue

        local app_name s3_file
        app_name="$(basename "${app_path}")"
        s3_file="${base_s3_path}/${app_name}.tar.gz"

        info "Compactando: ${app_path} → ${s3_file}"

        set +e
        tar -czf - \
            --exclude="wp-content/cache" \
            --exclude="wp-content/upgrade" \
            --exclude="wp-content/ai1wm-backups" \
            --exclude="wp-content/updraft" \
            --exclude="wp-content/backups-dup-lite" \
            --exclude="wp-content/wpvividbackups" \
            --exclude="node_modules" \
            --exclude=".git" \
            -C "$(dirname "${app_path}")" "${app_name}" 2>>"${LOG_FILE}" \
            | aws s3 cp - "${s3_file}" \
                --region "${AWS_DEFAULT_REGION}" >>"${LOG_FILE}" 2>&1
        local rc=("${PIPESTATUS[@]}")
        set -e

        if (( rc[0] == 0 && rc[1] == 0 )); then
            app_count=$((app_count + 1))
        else
            warn "Falha ao compactar/enviar: ${app_path} (tar=${rc[0]}, aws=${rc[1]})"
            status_add_error "archive falhou: ${app_name} (tar=${rc[0]}, aws=${rc[1]})"
            fail_count=$((fail_count + 1))
        fi
    done < <(find "${BACKUP_SOURCE}" -mindepth 1 -maxdepth 1 -type d | sort)

    STATUS_ARCHIVE_APPS_OK=${app_count}
    STATUS_ARCHIVE_APPS_FAIL=${fail_count}

    info "Backup compactado semanal finalizado: ${app_count} site(s) OK, ${fail_count} falha(s)."

    # NOTA: a retenção/expiração dos .tar.gz é feita por uma S3 Lifecycle Rule
    # no próprio bucket (prefixo Snapshots/, expira após N dias) — configurada
    # uma única vez pelo instalador. Por isso o script NÃO apaga os baixáveis
    # aqui. A variável ARCHIVE_KEEP_WEEKS fica só como referência da janela
    # desejada (o valor efetivo é o "Days" da regra de lifecycle).
}

# ---------------------------------------------------------------------------
# RETENÇÃO (restic)
# ---------------------------------------------------------------------------

run_forget() {
    info "Aplicando retenção: daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}"

    local forget_flags=(
        forget
        --keep-daily   "${KEEP_DAILY}"
        --keep-weekly  "${KEEP_WEEKLY}"
        --keep-monthly "${KEEP_MONTHLY}"
        --prune
        --group-by "host,paths"
    )

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Simulando retenção."
        restic "${forget_flags[@]}" --dry-run
        return 0
    fi

    restic "${forget_flags[@]}" || warn "Falha durante forget/prune. Verifique o log."
    info "Retenção finalizada."
}

# ---------------------------------------------------------------------------
# CHECK DE INTEGRIDADE
# ---------------------------------------------------------------------------

run_check() {
    local today_dow
    today_dow="$(date +%w)"

    if [[ "${FORCE_CHECK}" == "true" ]] || [[ "${today_dow}" == "${CHECK_DAY}" ]]; then
        info "Executando check de integridade. Subset: ${CHECK_DATA_SUBSET}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            warn "[DRY-RUN] Pulando check."
            return 0
        fi

        STATUS_CHECK_RAN="true"
        if ! restic check --read-data-subset="${CHECK_DATA_SUBSET}"; then
            warn "restic check encontrou problemas. Rode 'restic check --read-data' completo se necessário."
            status_add_error "restic check encontrou problemas"
        fi

        info "Check finalizado."
    else
        info "Check pulado. Configurado para o dia da semana: ${CHECK_DAY} (hoje: ${today_dow})"
    fi
}

# ---------------------------------------------------------------------------
# TESTE DE RESTORE (--test-restore)
# ---------------------------------------------------------------------------
# Restaura o snapshot mais recente para um diretório temporário, validando
# de ponta a ponta que os backups são de fato recuperáveis. Não altera nada
# no repositório, em /var/www nem nos bancos.

run_test_restore() {
    info "════════════════════════════════════════════"
    info "TESTE DE RESTORE — validando recuperabilidade"
    info "════════════════════════════════════════════"

    local latest
    latest="$(restic snapshots --json 2>>"${LOG_FILE}" \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)"

    if [[ -z "${latest}" ]]; then
        die "Nenhum snapshot encontrado para testar restore."
    fi
    info "Snapshot mais recente: ${latest}"

    RESTORE_TEST_DIR="$(mktemp -d)"
    info "Restaurando amostra para: ${RESTORE_TEST_DIR}"

    # Restaura apenas um subconjunto para ser rápido: o diretório de dumps.
    # (--include limita o que é materializado; ajuste conforme necessário.)
    if ! restic restore "${latest}" \
            --target "${RESTORE_TEST_DIR}" \
            --include "${DB_DUMP_DIR}" 2>>"${LOG_FILE}"; then
        die "Falha ao restaurar amostra do snapshot ${latest}."
    fi

    # Valida que ao menos um dump foi restaurado e está legível:
    #   *.dump (pg_dump -Fc)  → pg_restore --list lê o índice interno
    #   globals.sql.gz        → gzip -t
    # pg_restore --list não conecta em banco nenhum — só lê o arquivo.
    local restored_dump
    restored_dump="$(find "${RESTORE_TEST_DIR}" -type f -name "*.dump" | head -1 || true)"

    if [[ -n "${restored_dump}" ]]; then
        info "Validando integridade do dump restaurado: ${restored_dump}"
        if "${PG_RESTORE_BIN}" --list "${restored_dump}" >/dev/null 2>>"${LOG_FILE}"; then
            info "Dump restaurado e íntegro (pg_restore --list OK): ${restored_dump}"
        else
            die "Dump restaurado está CORROMPIDO: ${restored_dump}. FALHA no teste."
        fi
    else
        warn "Nenhum .dump na amostra restaurada (talvez não haja bancos). Validando arquivos genéricos."
        local restored_gz
        restored_gz="$(find "${RESTORE_TEST_DIR}" -type f -name "*.sql.gz" | head -1 || true)"
        if [[ -n "${restored_gz}" ]]; then
            gzip -t "${restored_gz}" 2>>"${LOG_FILE}" \
                || die "Arquivo restaurado está CORROMPIDO: ${restored_gz}. FALHA no teste."
            info "Arquivo restaurado e íntegro (gzip -t OK): ${restored_gz}"
        else
            local any_file
            any_file="$(find "${RESTORE_TEST_DIR}" -type f | head -1 || true)"
            [[ -z "${any_file}" ]] && die "Restore não materializou nenhum arquivo. FALHA no teste."
            info "Arquivo restaurado com sucesso: ${any_file}"
        fi
    fi

    info "════════════════════════════════════════════"
    info "TESTE DE RESTORE CONCLUÍDO COM SUCESSO ✅"
    info "════════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# RESUMO
# ---------------------------------------------------------------------------

print_summary() {
    info "Resumo dos snapshots:"
    restic snapshots --compact || true

    # Coleta métricas do repositório para o status (não crítico se falhar).
    STATUS_SNAPSHOTS_TOTAL="$(restic snapshots --json 2>/dev/null \
        | grep -o '"short_id"' | wc -l | tr -d ' ' || true)"
    STATUS_REPO_SIZE="$(restic stats --mode raw-data 2>/dev/null \
        | grep -i 'Total Size' | sed 's/.*:[[:space:]]*//' || true)"
}

# ---------------------------------------------------------------------------
# STATUS JSON — grava o resultado do backup localmente e no S3
# ---------------------------------------------------------------------------

# Escapa uma string para uso seguro dentro de JSON (aspas, barra, controles).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # barra invertida primeiro
    s="${s//\"/\\\"}"   # aspas
    s="${s//$'\t'/\\t}" # tab
    s="${s//$'\r'/\\r}" # CR
    s="${s//$'\n'/\\n}" # LF
    printf '%s' "${s}"
}

# Monta o array JSON de erros a partir de STATUS_ERRORS[].
build_errors_json() {
    local out="[" first=true e
    for e in "${STATUS_ERRORS[@]+"${STATUS_ERRORS[@]}"}"; do
        [[ "${first}" == "true" ]] && first=false || out+=","
        out+="\"$(json_escape "${e}")\""
    done
    out+="]"
    printf '%s' "${out}"
}

# Grava o JSON de status. Chamada SEMPRE no final (trap), com o status derivado
# do código de saída. Grava sempre o arquivo local; tenta o S3 se possível.
# $1 = "success" | "partial" | "error"
write_status() {
    [[ "${STATUS_WRITTEN}" == "true" ]] && return 0
    STATUS_WRITTEN="true"

    # Em modo dry-run ou test-restore não faz sentido publicar status de backup.
    [[ "${DRY_RUN}" == "true" ]] && return 0
    [[ "${TEST_RESTORE}" == "true" ]] && return 0

    local overall="$1"
    local host finished_at started errors_json
    host="$(hostname -s)"
    finished_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    started="${STATUS_STARTED_AT:-${finished_at}}"
    errors_json="$(build_errors_json)"

    # duração em segundos (se conseguimos parsear started).
    local dur="null" s_epoch f_epoch
    s_epoch="$(date -d "${started}" +%s 2>/dev/null || echo "")"
    f_epoch="$(date -d "${finished_at}" +%s 2>/dev/null || echo "")"
    if [[ -n "${s_epoch}" && -n "${f_epoch}" ]]; then
        dur=$(( f_epoch - s_epoch ))
    fi

    local json
    json="$(cat <<JSON
{
  "host": "$(json_escape "${host}")",
  "status": "$(json_escape "${overall}")",
  "started_at": "$(json_escape "${started}")",
  "finished_at": "$(json_escape "${finished_at}")",
  "duration_seconds": ${dur},
  "databases": { "ok": ${STATUS_DB_OK}, "failed": ${STATUS_DB_FAIL} },
  "weekly_archive": { "ran": ${STATUS_ARCHIVE_RAN}, "apps_ok": ${STATUS_ARCHIVE_APPS_OK}, "apps_failed": ${STATUS_ARCHIVE_APPS_FAIL} },
  "restic_snapshot_id": "$(json_escape "${STATUS_SNAPSHOT_ID}")",
  "repo_size": "$(json_escape "${STATUS_REPO_SIZE}")",
  "snapshots_total": "$(json_escape "${STATUS_SNAPSHOTS_TOTAL}")",
  "check_ran": ${STATUS_CHECK_RAN},
  "errors": ${errors_json},
  "script_version": "$(json_escape "${STATUS_SCRIPT_VERSION}")"
}
JSON
)"

    # 1) Grava sempre o arquivo local (auditoria / fallback).
    local status_dir
    status_dir="$(dirname "${STATUS_LOCAL_FILE}")"
    [[ -d "${status_dir}" ]] || mkdir -p "${status_dir}" 2>/dev/null || true
    printf '%s\n' "${json}" > "${STATUS_LOCAL_FILE}" 2>/dev/null || true

    # 2) Tenta enviar ao S3 (só se houver aws + credenciais + bucket).
    #    Exporta as credenciais aqui também: em falha PRECOCE (ex.: restic
    #    ausente, que aborta antes de export_restic_env), as variáveis foram
    #    lidas pelo source do env mas ainda não estavam exportadas para o aws.
    if command -v aws &>/dev/null \
        && [[ -n "${S3_BUCKET}" && -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
        local s3_dest="s3://${S3_BUCKET}/${STATUS_S3_PREFIX}/${host}.json"
        if printf '%s\n' "${json}" | aws s3 cp - "${s3_dest}" \
            --content-type "application/json" \
            --region "${AWS_DEFAULT_REGION}" &>/dev/null; then
            info "Status publicado no S3: ${s3_dest}"
        else
            warn "Não foi possível publicar o status no S3 (backup em si não é afetado)."
        fi
    else
        warn "Status gravado apenas localmente em ${STATUS_LOCAL_FILE} (aws/credenciais indisponíveis)."
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    # Marca o início o quanto antes, para o status ter timestamp mesmo se algo
    # falhar já no carregamento do env.
    STATUS_STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    # Evita o aviso "could not change directory" quando comandos rodam como o
    # usuário postgres via sudo a partir de um cwd que ele não lê (ex.: /root).
    # Todos os caminhos do script são absolutos, então isso é inofensivo.
    cd /

    # Carrega o env PRIMEIRO: ele pode redefinir LOG_FILE e LOCK_FILE, que são
    # usados logo abaixo por rotate_log e acquire_lock.
    load_env_file

    rotate_log
    acquire_lock

    info "════════════════════════════════════════════"
    info "Backup iniciado | host: $(hostname -s) | data: $(date '+%Y-%m-%d %H:%M:%S')"
    info "════════════════════════════════════════════"

    [[ "${DRY_RUN}" == "true" ]] && warn "Modo DRY-RUN ativo."

    resolve_pg_bins
    validate_env
    export_restic_env
    setup_pg_auth

    notify_start

    # Modo teste de restore: valida e sai, sem rodar o backup.
    if [[ "${TEST_RESTORE}" == "true" ]]; then
        run_test_restore
        notify_success
        exit 0
    fi

    build_exclude_file
    init_repo_if_needed
    dump_databases
    run_backup
    run_weekly_app_archives
    run_forget
    run_check
    print_summary

    info "════════════════════════════════════════════"
    info "Backup finalizado | host: $(hostname -s) | data: $(date '+%Y-%m-%d %H:%M:%S')"
    info "════════════════════════════════════════════"

    notify_success
}

main
