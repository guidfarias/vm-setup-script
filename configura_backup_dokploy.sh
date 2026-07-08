#!/bin/bash
# =============================================================================
# restic-backup-dokploy.sh — Backup de servidor Dokploy para S3 (restic + tar.gz)
# CIPNET — variante para servidores Dokploy (painel PaaS via Docker Swarm)
#
# O que é protegido:
#   - O Postgres INTERNO do Dokploy E qualquer Postgres de CLIENTE criado
#     pelo painel — descoberta automática por imagem de container. Dump
#     lógico via `docker exec` em ${DB_DUMP_DIR}/container-<serviço>/,
#     sem instalar cliente Postgres no host e sem senha.
#   - /etc/dokploy: configs do Traefik, certificados Let's Encrypt (e os
#     clones de build dos apps, de brinde).
#   - Volumes Docker (/var/lib/docker/volumes): uploads/persistência dos
#     apps. Os volumes de DADOS dos bancos ficam fora do snapshot — já são
#     cobertos pelos dumps lógicos (cópia crua de banco rodando corrompe).
#   O código dos apps é reconstruível via Git e não depende deste backup.
#   Containers de banco NÃO-Postgres (mysql/mongo) geram aviso no log e
#   status "partial" até serem cobertos.
#
# O que este script faz:
#   1. Carrega variáveis de /etc/restic/env (valida permissões 600/root)
#   2. Valida pré-requisitos (docker, restic, credenciais, espaço em disco)
#   3. Dump do banco do Dokploy em ${DB_DUMP_DIR} (pg_dump -Fc dentro do
#      container + pg_dumpall --globals-only)
#   4. Backup incremental de /etc/dokploy + dumps com restic
#   5. Gera .tar.gz baixáveis e envia ao S3 (dia configurável / FORCE_ARCHIVE)
#   6. Aplica retenção (forget --prune)
#   7. Executa check de integridade semanal
#   8. (Opcional) Testa restore de amostra: --test-restore
#
# Uso:
#   bash restic-backup-dokploy.sh                  # backup normal
#   bash restic-backup-dokploy.sh --dry-run        # simula, nada é enviado
#   bash restic-backup-dokploy.sh --check          # força check de integridade
#   bash restic-backup-dokploy.sh --test-restore   # testa restauração e sai
#   FORCE_ARCHIVE=true bash restic-backup-dokploy.sh
#
# Restauração rápida (referência):
#   rr snapshots
#   rr restore latest --target /tmp/rest --include /var/backups/db
#   docker exec -i $(docker ps -q -f name=dokploy-postgres) \
#       pg_restore -U dokploy --clean --if-exists -d dokploy \
#       < container-dokploy-postgres/dokploy.dump
#   (bancos de cliente: mesmo formato, em container-<serviço>/<banco>.dump,
#    com o usuário do container — veja POSTGRES_USER nas envs dele)
#   gunzip -c container-<serviço>/globals.sql.gz | docker exec -i <container> psql -U <user>
#   /etc/dokploy → restaurar os arquivos e reiniciar o serviço dokploy.
#   Volumes → restaurar o conteúdo em /var/lib/docker/volumes/<vol>/_data.
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

# Diretório de configs do Dokploy (Traefik, certificados Let's Encrypt).
BACKUP_SOURCE="${BACKUP_SOURCE:-/etc/dokploy}"

# Fica FORA de BACKUP_SOURCE; o restic faz snapshot dele junto (ver run_backup).
DB_DUMP_DIR="${DB_DUMP_DIR:-/var/backups/db}"

# --- Bancos (painel + clientes) ---
# O container do PAINEL é localizado por filtro de nome e é obrigatório
# (sem ele o backup aborta preservando os dumps antigos).
DOKPLOY_PG_FILTER="${DOKPLOY_PG_FILTER:-dokploy-postgres}"
# Descoberta automática: TODO container cuja imagem case com o regex abaixo
# é dumpado (usuário/banco lidos das envs do próprio container). Amplie se
# usar imagens derivadas: ex. 'postgres|pgvector|timescale'.
DB_CONTAINER_IMAGE_REGEX="${DB_CONTAINER_IMAGE_REGEX:-postgres}"
# Bancos ignorados no dump (regex ERE). Padrão: nenhum — o db 'postgres'
# de manutenção é minúsculo e às vezes clientes o usam sem querer.
PG_EXCLUDE_REGEX="${PG_EXCLUDE_REGEX:-^$}"
# Volumes Docker no snapshot restic (uploads/persistência dos apps). Os
# volumes de DADOS dos bancos Postgres são excluídos automaticamente.
BACKUP_DOCKER_VOLUMES="${BACKUP_DOCKER_VOLUMES:-true}"
DOCKER_VOLUMES_DIR="${DOCKER_VOLUMES_DIR:-/var/lib/docker/volumes}"

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
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# ---------------------------------------------------------------------------
# STATUS PARA MONITORAMENTO (JSON gravado no S3 em Monitoramento/<host>.json)
# ---------------------------------------------------------------------------
# Mesmo schema das variantes MySQL/PostgreSQL — o painel/MCP lê a frota
# inteira do mesmo jeito. Arquivo local de status (fallback / auditoria):
STATUS_LOCAL_FILE="${STATUS_LOCAL_FILE:-/var/log/restic-status.json}"
STATUS_S3_PREFIX="${STATUS_S3_PREFIX:-Monitoramento}"
STATUS_SCRIPT_VERSION="2026-07-dokploy-2"

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
RESTORE_TEST_DIR=""
PG_CONTAINER=""
REPO_EXISTS="false"

cleanup() {
    # Preserva o código de saída original: como este é o trap de EXIT, o status
    # do último comando aqui viraria o exit do script. `return 0` garante que
    # um backup bem-sucedido não seja reportado como falha ao cron.
    local exit_code=$?

    # Publica o status de monitoramento SEMPRE (sucesso, falha parcial ou falha
    # precoce). Classificação:
    #   - exit != 0                    → "error"   (abortou; ex.: restic ausente)
    #   - exit == 0 mas houve erros    → "partial" (ex.: dump do banco falhou)
    #   - exit == 0 e sem erros        → "success"
    local overall="success"
    if (( exit_code != 0 )); then
        overall="error"
    elif (( ${#STATUS_ERRORS[@]} > 0 )); then
        overall="partial"
    fi
    write_status "${overall}" || true

    [[ -n "${EXCLUDE_FILE}" ]]     && rm -f "${EXCLUDE_FILE}"
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
        --force-archive) FORCE_ARCHIVE=true ;;
        --help|-h)
            cat <<'HELP'
Uso:
  bash restic-backup-dokploy.sh                  # backup normal
  bash restic-backup-dokploy.sh --dry-run        # simula, nada é enviado ao S3
  bash restic-backup-dokploy.sh --check          # força check de integridade
  bash restic-backup-dokploy.sh --test-restore   # testa restauração e sai
  bash restic-backup.sh --force-archive # força o compactado semanal agora
  FORCE_ARCHIVE=true bash restic-backup-dokploy.sh
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

validate_env() {
    local errors=0

    require_cmd restic "Instale o restic (https://restic.net)."          || errors=$((errors + 1))
    require_cmd docker "Este servidor deveria rodar Dokploy (Docker)."   || errors=$((errors + 1))
    require_cmd gzip   "apt install gzip -y"                             || errors=$((errors + 1))

    if command -v docker &>/dev/null && ! docker info &>/dev/null; then
        error "Docker instalado mas o daemon não responde (docker info falhou)."
        errors=$((errors + 1))
    fi

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
# CONTAINERS DE BANCO (painel + clientes)
# ---------------------------------------------------------------------------

# Executa um comando dentro de um container ($1 = nome). A variante _i passa
# o stdin (pg_restore no teste de restore).
pg_exec()   { local c="$1"; shift; docker exec    "${c}" "$@"; }
pg_exec_i() { local c="$1"; shift; docker exec -i "${c}" "$@"; }

# Localiza o container do Postgres do PAINEL (Swarm gera nomes tipo
# "dokploy-postgres.1.abc123"). Preenche PG_CONTAINER; retorna 1 se não achar.
find_pg_container() {
    PG_CONTAINER="$(docker ps --filter "name=${DOKPLOY_PG_FILTER}" \
        --format '{{.Names}}' 2>>"${LOG_FILE}" | head -1 || true)"
    if [[ -z "${PG_CONTAINER}" ]]; then
        error "Container do Postgres do painel não encontrado (filtro: name=${DOKPLOY_PG_FILTER})."
        return 1
    fi
    return 0
}

# Lista containers Postgres em execução: linhas "nome<TAB>imagem".
list_db_containers() {
    docker ps --format '{{.Names}}\t{{.Image}}' 2>>"${LOG_FILE}" \
        | awk -F'\t' -v re="${DB_CONTAINER_IMAGE_REGEX}" '$2 ~ re {print $1 "\t" $2}' || true
}

# ---------------------------------------------------------------------------
# INICIALIZA REPOSITÓRIO (se necessário)
# ---------------------------------------------------------------------------

init_repo_if_needed() {
    if restic cat config &>/dev/null; then
        info "Repositório restic já existe em: ${RESTIC_REPOSITORY}"
        REPO_EXISTS="true"
        return 0
    fi

    info "Repositório não encontrado. Inicializando: ${RESTIC_REPOSITORY}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando inicialização do repositório."
        return 0
    fi

    restic init || die "Falha ao inicializar repositório restic."
    REPO_EXISTS="true"
    info "Repositório inicializado com sucesso."
}

# ---------------------------------------------------------------------------
# DUMP DO BANCO DO DOKPLOY
# ---------------------------------------------------------------------------

check_disk_space() {
    mkdir -p "${DB_DUMP_DIR}"
    local free_mb
    free_mb="$(df -Pm "${DB_DUMP_DIR}" | awk 'NR==2 {print $4}')"
    if [[ -n "${free_mb}" ]] && (( free_mb < MIN_FREE_MB )); then
        die "Espaço insuficiente em ${DB_DUMP_DIR}: ${free_mb}MB livres (< ${MIN_FREE_MB}MB exigidos)."
    fi
    info "Espaço livre em ${DB_DUMP_DIR}: ${free_mb}MB (mínimo ${MIN_FREE_MB}MB) OK."
}

# Dumpa UM container Postgres para ${DB_DUMP_DIR}/container-<serviço>/.
# Usuário/banco de conexão vêm das envs do próprio container (POSTGRES_USER/
# POSTGRES_DB — o painel usa dokploy/dokploy). Retorna 1 se o container
# estiver inacessível (dumps antigos dele preservados). Incrementa
# STATUS_DB_OK / STATUS_DB_FAIL diretamente.
dump_pg_container() {
    local cname="$1"
    local svc="${cname%%.*}"      # dokploy-postgres.1.abc → dokploy-postgres
    local cdir="${DB_DUMP_DIR}/container-${svc}"

    local pguser pgdb
    pguser="$(pg_exec "${cname}" printenv POSTGRES_USER 2>/dev/null || true)"
    pguser="${pguser:-postgres}"
    pgdb="$(pg_exec "${cname}" printenv POSTGRES_DB 2>/dev/null || true)"
    pgdb="${pgdb:-${pguser}}"

    info "── Container ${svc} (user=${pguser}) ──"
    if ! pg_exec "${cname}" psql -X -U "${pguser}" -d "${pgdb}" -Atqc "SELECT 1;" &>/dev/null; then
        error "Falha ao conectar no Postgres do container ${svc}. Dumps antigos dele preservados."
        status_add_error "conexão falhou: container ${svc}"
        return 1
    fi
    info "Conexão OK (${svc})."

    mkdir -p "${cdir}"
    chmod 700 "${cdir}"
    info "Limpando dumps antigos em ${cdir}"
    find "${cdir}" -type f \( -name "*.dump" -o -name "*.sql.gz" \) -delete

    # Globals: roles e permissões — necessários para restaurar em host novo.
    info "Dumping globals (roles/permissões): container-${svc}/globals.sql.gz"
    set +e
    pg_exec "${cname}" pg_dumpall -U "${pguser}" --globals-only 2>>"${LOG_FILE}" \
        | gzip -9 > "${cdir}/globals.sql.gz"
    local globals_rc=${PIPESTATUS[0]}
    set -e
    if (( globals_rc == 0 )); then
        chmod 600 "${cdir}/globals.sql.gz"
    else
        error "Falha no dump dos globals de ${svc} (rc=${globals_rc})"
        status_add_error "dump falhou: globals ${svc} (rc=${globals_rc})"
        rm -f "${cdir}/globals.sql.gz"
    fi

    # Lista bancos do container (templates ficam de fora na própria query).
    local db_list
    db_list="$(pg_exec "${cname}" psql -X -U "${pguser}" -d "${pgdb}" -Atqc \
        "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;" \
        2>>"${LOG_FILE}" | grep -Ev "${PG_EXCLUDE_REGEX}" || true)"

    if [[ -z "${db_list}" ]]; then
        warn "Nenhum banco de usuário no container ${svc}."
        return 0
    fi

    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue
        local dump_file="${cdir}/${db}.dump"

        info "Dumping banco: ${db} (${svc})"

        # Formato custom (-Fc): já sai comprimido e restaura com pg_restore.
        # O redirecionamento é do host — o arquivo fica com dono root.
        set +e
        pg_exec "${cname}" pg_dump -U "${pguser}" --format=custom --compress=6 \
            "${db}" 2>>"${LOG_FILE}" > "${dump_file}"
        local dump_rc=$?
        set -e

        if (( dump_rc == 0 )); then
            chmod 600 "${dump_file}"
            STATUS_DB_OK=$((STATUS_DB_OK + 1))
        else
            error "Falha no dump do banco ${db} em ${svc} (rc=${dump_rc})"
            status_add_error "dump falhou: ${db}@${svc} (rc=${dump_rc})"
            rm -f "${dump_file}"
            STATUS_DB_FAIL=$((STATUS_DB_FAIL + 1))
        fi
    done <<< "${db_list}"

    return 0
}

dump_databases() {
    info "Iniciando dump dos bancos (painel + clientes) em ${DB_DUMP_DIR}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando dump de bancos."
        return 0
    fi

    # O Postgres do PAINEL precisa existir — sem ele o servidor está doente
    # e nada é apagado.
    find_pg_container || die "Sem container do Postgres do painel. Dumps antigos preservados."
    info "Container do painel: ${PG_CONTAINER}"

    local containers
    containers="$(list_db_containers)"
    if [[ -z "${containers}" ]]; then
        die "Nenhum container Postgres em execução (regex de imagem: ${DB_CONTAINER_IMAGE_REGEX}). Dumps antigos preservados."
    fi

    check_disk_space
    chmod 700 "${DB_DUMP_DIR}"

    local reachable=0 cname
    while IFS=$'\t' read -r cname _; do
        [[ -z "${cname}" ]] && continue
        if dump_pg_container "${cname}"; then
            reachable=$((reachable + 1))
        fi
    done <<< "${containers}"

    if (( reachable == 0 )); then
        die "Nenhum container Postgres acessível. Dumps antigos preservados."
    fi

    # Bancos que o script AINDA não cobre (dump lógico é só para Postgres).
    # Gera status "partial" de propósito: o monitoramento cobra até cobrirmos.
    local others
    others="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | awk -F'\t' '$2 ~ /mysql|mariadb|mongo/ {print $1}' | tr '\n' ' ' || true)"
    if [[ -n "${others// /}" ]]; then
        warn "Containers de banco NÃO-Postgres detectados (sem dump lógico ainda): ${others}"
        status_add_error "bancos não cobertos: ${others}"
    fi

    # Remove resquícios de layout antigo: arquivos soltos na raiz de
    # DB_DUMP_DIR (os dumps atuais vivem em container-<serviço>/).
    find "${DB_DUMP_DIR}" -maxdepth 1 -type f \( -name "*.dump" -o -name "*.sql.gz" \) -delete

    info "Dump finalizado: ${STATUS_DB_OK} banco(s) OK, ${STATUS_DB_FAIL} falha(s)."

    if (( STATUS_DB_FAIL > 0 )); then
        warn "Alguns bancos falharam no dump. Backup continuará, mas revise o log."
    fi
}

# ---------------------------------------------------------------------------
# ARQUIVO DE EXCLUSÕES
# ---------------------------------------------------------------------------

build_exclude_file() {
    EXCLUDE_FILE="$(mktemp)"
    cat > "${EXCLUDE_FILE}" << 'EXCLUDES'
# Arquivos temporários e de processo
*.tmp
*.swp
*.sock
*.pid
.DS_Store

# Logs (os de deploy do Dokploy podem ser grandes e são recriáveis)
*.log
EXCLUDES
    # Diretório de logs do Dokploy (caminho depende de BACKUP_SOURCE).
    printf '%s\n' "${BACKUP_SOURCE}/logs" >> "${EXCLUDE_FILE}"
}

# Exclui do snapshot os volumes de DADOS dos containers Postgres: eles já
# estão protegidos pelos dumps lógicos, e cópia crua de banco rodando sai
# inconsistente. Os demais volumes (uploads/persistência dos apps) ficam.
exclude_db_volumes() {
    [[ "${BACKUP_DOCKER_VOLUMES}" != "true" ]] && return 0
    local cname vol
    while IFS=$'\t' read -r cname _; do
        [[ -z "${cname}" ]] && continue
        while IFS= read -r vol; do
            [[ -z "${vol}" ]] && continue
            printf '%s\n' "${DOCKER_VOLUMES_DIR}/${vol}" >> "${EXCLUDE_FILE}"
            info "Volume de banco fora do snapshot (coberto pelo dump): ${vol}"
        done < <(docker inspect -f \
            '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' \
            "${cname}" 2>/dev/null || true)
    done <<< "$(list_db_containers)"
}

# ---------------------------------------------------------------------------
# BACKUP DO /ETC/DOKPLOY + DUMPS
# ---------------------------------------------------------------------------

run_backup() {
    local backup_paths=("${BACKUP_SOURCE}" "${DB_DUMP_DIR}")
    if [[ "${BACKUP_DOCKER_VOLUMES}" == "true" && -d "${DOCKER_VOLUMES_DIR}" ]]; then
        backup_paths+=("${DOCKER_VOLUMES_DIR}")
    fi

    info "Iniciando backup restic de: ${backup_paths[*]}"
    info "Repositório: ${RESTIC_REPOSITORY}"

    local restic_flags=(
        backup
        "${backup_paths[@]}"
        --exclude-file="${EXCLUDE_FILE}"
        --tag "host=$(hostname -s)"
        --tag "dokploy"
        --tag "daily"
        --one-file-system
    )

    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ "${REPO_EXISTS}" != "true" ]]; then
            warn "[DRY-RUN] Repositório ainda não existe (será criado na 1ª execução real). Pulando simulação do backup."
            return 0
        fi
        warn "[DRY-RUN] Simulando backup. Nada será enviado ao S3."
        restic "${restic_flags[@]}" --dry-run
        return 0
    fi

    restic "${restic_flags[@]}" || die "Snapshot restic falhou."
    info "Backup restic finalizado com sucesso."

    STATUS_SNAPSHOT_ID="$(restic snapshots latest --json 2>/dev/null \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)"
}

# ---------------------------------------------------------------------------
# BACKUP SEMANAL — .tar.gz baixáveis (dia configurável ou FORCE_ARCHIVE)
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

    info "Iniciando backup compactado semanal."
    info "Destino S3: ${base_s3_path}"

    # Dumps do banco.
    if [[ -d "${DB_DUMP_DIR}" ]]; then
        info "Gerando arquivo compactado dos dumps do banco."
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

    # /etc/dokploy inteiro (Traefik + certificados) — é pequeno.
    local etc_name s3_file
    etc_name="$(basename "${BACKUP_SOURCE}")"
    s3_file="${base_s3_path}/dokploy-etc.tar.gz"

    info "Compactando: ${BACKUP_SOURCE} → ${s3_file}"

    set +e
    tar -czf - \
        --exclude="logs" \
        -C "$(dirname "${BACKUP_SOURCE}")" "${etc_name}" 2>>"${LOG_FILE}" \
        | aws s3 cp - "${s3_file}" \
            --region "${AWS_DEFAULT_REGION}" >>"${LOG_FILE}" 2>&1
    local rc=("${PIPESTATUS[@]}")
    set -e

    if (( rc[0] == 0 && rc[1] == 0 )); then
        STATUS_ARCHIVE_APPS_OK=1
    else
        warn "Falha ao compactar/enviar: ${BACKUP_SOURCE} (tar=${rc[0]}, aws=${rc[1]})"
        status_add_error "archive falhou: dokploy-etc (tar=${rc[0]}, aws=${rc[1]})"
        STATUS_ARCHIVE_APPS_FAIL=1
    fi

    info "Backup compactado semanal finalizado."

    # NOTA: a retenção/expiração dos .tar.gz é feita por uma S3 Lifecycle Rule
    # no próprio bucket (prefixo Snapshots/, expira após N dias) — configurada
    # uma única vez pelo instalador. ARCHIVE_KEEP_WEEKS é só referência.
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
        if [[ "${REPO_EXISTS}" != "true" ]]; then
            warn "[DRY-RUN] Repositório ainda não existe. Pulando simulação da retenção."
            return 0
        fi
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
# Restaura o snapshot mais recente para um diretório temporário e valida o
# dump com `pg_restore --list` DENTRO do container (não conecta em banco
# nenhum, só lê o índice do arquivo). Não altera nada.

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

    if ! restic restore "${latest}" \
            --target "${RESTORE_TEST_DIR}" \
            --include "${DB_DUMP_DIR}" 2>>"${LOG_FILE}"; then
        die "Falha ao restaurar amostra do snapshot ${latest}."
    fi

    local restored_dump
    restored_dump="$(find "${RESTORE_TEST_DIR}" -type f -name "*.dump" | head -1 || true)"

    if [[ -n "${restored_dump}" ]]; then
        info "Validando integridade do dump restaurado: ${restored_dump}"
        find_pg_container || die "Sem container do Postgres para validar o dump."
        if pg_exec_i "${PG_CONTAINER}" pg_restore --list < "${restored_dump}" >/dev/null 2>>"${LOG_FILE}"; then
            info "Dump restaurado e íntegro (pg_restore --list OK): ${restored_dump}"
        else
            die "Dump restaurado está CORROMPIDO: ${restored_dump}. FALHA no teste."
        fi
    else
        warn "Nenhum .dump na amostra restaurada. Validando arquivos genéricos."
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
    if [[ "${DRY_RUN}" == "true" && "${REPO_EXISTS}" != "true" ]]; then
        info "Resumo pulado (repositório ainda não existe)."
        return 0
    fi
    info "Resumo dos snapshots:"
    restic snapshots --compact || true

    STATUS_SNAPSHOTS_TOTAL="$(restic snapshots --json 2>/dev/null \
        | grep -o '"short_id"' | wc -l | tr -d ' ' || true)"
    STATUS_REPO_SIZE="$(restic stats --mode raw-data 2>/dev/null \
        | grep -i 'Total Size' | sed 's/.*:[[:space:]]*//' || true)"
}

# ---------------------------------------------------------------------------
# STATUS JSON — grava o resultado do backup localmente e no S3
# ---------------------------------------------------------------------------

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # barra invertida primeiro
    s="${s//\"/\\\"}"   # aspas
    s="${s//$'\t'/\\t}" # tab
    s="${s//$'\r'/\\r}" # CR
    s="${s//$'\n'/\\n}" # LF
    printf '%s' "${s}"
}

build_errors_json() {
    local out="[" first=true e
    for e in "${STATUS_ERRORS[@]+"${STATUS_ERRORS[@]}"}"; do
        [[ "${first}" == "true" ]] && first=false || out+=","
        out+="\"$(json_escape "${e}")\""
    done
    out+="]"
    printf '%s' "${out}"
}

# $1 = "success" | "partial" | "error"
write_status() {
    [[ "${STATUS_WRITTEN}" == "true" ]] && return 0
    STATUS_WRITTEN="true"

    [[ "${DRY_RUN}" == "true" ]] && return 0
    [[ "${TEST_RESTORE}" == "true" ]] && return 0

    local overall="$1"
    local host finished_at started errors_json
    host="$(hostname -s)"
    finished_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    started="${STATUS_STARTED_AT:-${finished_at}}"
    errors_json="$(build_errors_json)"

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

    local status_dir
    status_dir="$(dirname "${STATUS_LOCAL_FILE}")"
    [[ -d "${status_dir}" ]] || mkdir -p "${status_dir}" 2>/dev/null || true
    printf '%s\n' "${json}" > "${STATUS_LOCAL_FILE}" 2>/dev/null || true

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
    STATUS_STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    # Carrega o env PRIMEIRO: ele pode redefinir LOG_FILE e LOCK_FILE, que são
    # usados logo abaixo por rotate_log e acquire_lock.
    load_env_file

    rotate_log
    acquire_lock

    info "════════════════════════════════════════════"
    info "Backup iniciado | host: $(hostname -s) | data: $(date '+%Y-%m-%d %H:%M:%S')"
    info "════════════════════════════════════════════"

    [[ "${DRY_RUN}" == "true" ]] && warn "Modo DRY-RUN ativo."

    validate_env
    export_restic_env

    notify_start

    # Modo teste de restore: valida e sai, sem rodar o backup.
    if [[ "${TEST_RESTORE}" == "true" ]]; then
        run_test_restore
        notify_success
        exit 0
    fi

    build_exclude_file
    exclude_db_volumes
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
