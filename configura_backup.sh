#!/bin/bash
# =============================================================================
# restic-backup.sh — Backup completo de /home para S3 (restic + tar.gz)
# RunCloud / CIPNET
#
# O que este script faz:
#   1. Carrega variáveis de /etc/restic/env (valida permissões 600/root)
#   2. Valida pré-requisitos (binários, credenciais, espaço em disco)
#   3. Faz dump de todos os bancos MySQL em ${DB_DUMP_DIR}
#      (credenciais via arquivo temporário — NÃO vazam no `ps aux`)
#   4. Faz backup incremental do /home completo com restic
#   5. Gera .tar.gz por aplicação e envia ao S3 (dia configurável / FORCE_ARCHIVE)
#   6. Aplica retenção (forget --prune)
#   7. Executa check de integridade semanal
#   8. (Opcional) Testa restore de amostra: --test-restore
#
# Uso:
#   bash restic-backup.sh                  # backup normal
#   bash restic-backup.sh --dry-run        # simula, nada é enviado
#   bash restic-backup.sh --check          # força check de integridade
#   bash restic-backup.sh --test-restore   # testa restauração de amostra
#   FORCE_ARCHIVE=true bash restic-backup.sh
#
# ⚠️  IMPORTANTE — RECUPERAÇÃO DE DESASTRE:
#   A RESTIC_PASSWORD é a ÚNICA forma de ler os backups restic. Se o servidor
#   for perdido/reprovisionado e você não tiver essa senha guardada EM OUTRO
#   LUGAR (gerenciador de senhas, cofre, etc.), TODOS os backups restic ficam
#   irrecuperáveis. Guarde-a fora do servidor. O mesmo vale para as chaves AWS.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO — defaults (sobrescritos pelo /etc/restic/env)
# ---------------------------------------------------------------------------

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-sa-east-1}"

S3_BUCKET="${S3_BUCKET:-cipnet-backups-runcloud}"
S3_PREFIX="${S3_PREFIX:-$(hostname -s)}"
RESTIC_S3_PREFIX="${RESTIC_S3_PREFIX:-Restic/${S3_PREFIX}}"

RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"

# Diretório de origem do backup (permite testar sem tocar em /home real)
BACKUP_SOURCE="${BACKUP_SOURCE:-/home}"

DB_DUMP_DIR="${DB_DUMP_DIR:-/home/backups/db}"

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-2}"
KEEP_MONTHLY="${KEEP_MONTHLY:-2}"

CHECK_DAY="${CHECK_DAY:-0}"
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
ARCHIVE_KEEP_WEEKS="${ARCHIVE_KEEP_WEEKS:-4}"

# ---------------------------------------------------------------------------
# ALERTAS (opcional) — Healthchecks.io (dead man's switch)
# ---------------------------------------------------------------------------
# Defina HEALTHCHECK_URL no /etc/restic/env para ativar. Deixe vazio p/ desligar.
# O script sinaliza início (/start), sucesso e falha (/fail) automaticamente.
# É a forma mais confiável de descobrir que o backup PAROU de rodar.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# ---------------------------------------------------------------------------
# ESTADO INTERNO / LIMPEZA
# ---------------------------------------------------------------------------

EXCLUDE_FILE=""
MYSQL_DEFAULTS_FILE=""
RESTORE_TEST_DIR=""

cleanup() {
    # Preserva o código de saída original: como este é o trap de EXIT, o status
    # do último comando aqui viraria o exit do script. `return 0` garante que
    # um backup bem-sucedido não seja reportado como falha ao cron.
    local exit_code=$?
    [[ -n "${EXCLUDE_FILE}" ]]        && rm -f "${EXCLUDE_FILE}"
    [[ -n "${MYSQL_DEFAULTS_FILE}" ]] && rm -f "${MYSQL_DEFAULTS_FILE}"
    [[ -n "${RESTORE_TEST_DIR}" ]]    && rm -rf "${RESTORE_TEST_DIR}"
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
  bash restic-backup.sh                  # backup normal
  bash restic-backup.sh --dry-run        # simula, nada é enviado ao S3
  bash restic-backup.sh --check          # força check de integridade
  bash restic-backup.sh --test-restore   # testa restauração de amostra e sai
  FORCE_ARCHIVE=true bash restic-backup.sh
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

    # O env contém a senha do root do MySQL e a RESTIC_PASSWORD.
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

validate_env() {
    local errors=0

    require_cmd restic    "Instale o restic (https://restic.net)."           || errors=$((errors + 1))
    require_cmd mysqldump "apt install mysql-client -y"                       || errors=$((errors + 1))
    require_cmd mysql     "apt install mysql-client -y"                       || errors=$((errors + 1))
    require_cmd gzip      "apt install gzip -y"                               || errors=$((errors + 1))

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
# CREDENCIAIS MYSQL — arquivo temporário (não vaza no `ps aux`)
# ---------------------------------------------------------------------------

build_mysql_defaults_file() {
    MYSQL_DEFAULTS_FILE="$(mktemp)"
    chmod 600 "${MYSQL_DEFAULTS_FILE}"
    {
        echo "[client]"
        echo "user=${MYSQL_USER}"
        echo "host=${MYSQL_HOST}"
        # Só escreve a senha se houver uma (permite auth por socket sem senha).
        if [[ -n "${MYSQL_PASSWORD}" ]]; then
            echo "password=${MYSQL_PASSWORD}"
        fi
    } > "${MYSQL_DEFAULTS_FILE}"
}

# Wrappers: sempre usam o defaults-file como PRIMEIRO argumento.
mysql_cmd()     { mysql     --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"; }
mysqldump_cmd() { mysqldump --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"; }

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
# DUMP DOS BANCOS MYSQL
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

dump_databases() {
    info "Iniciando dump dos bancos MySQL em ${DB_DUMP_DIR}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando dump de bancos."
        return 0
    fi

    # Valida conexão com MySQL ANTES de apagar dumps antigos.
    info "Testando conexão com MySQL..."
    if ! mysql_cmd --silent -e "SELECT 1;" &>/dev/null; then
        die "Falha ao conectar no MySQL. Dumps antigos preservados."
    fi
    info "Conexão com MySQL OK."

    check_disk_space

    chmod 700 "${DB_DUMP_DIR}"
    info "Limpando dumps antigos em ${DB_DUMP_DIR}"
    find "${DB_DUMP_DIR}" -type f -name "*.sql.gz" -delete

    local db_list
    db_list="$(mysql_cmd --skip-column-names --silent -e "SHOW DATABASES;" 2>>"${LOG_FILE}" \
        | grep -Ev "^(information_schema|performance_schema|sys|mysql)$" || true)"

    if [[ -z "${db_list}" ]]; then
        warn "Nenhum banco de usuário encontrado."
        return 0
    fi

    local ok=0 fail=0
    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue
        local dump_file="${DB_DUMP_DIR}/${db}.sql.gz"

        info "Dumping banco: ${db}"

        # PIPESTATUS captura a falha do mysqldump mesmo com pipe pro gzip.
        set +e
        mysqldump_cmd \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --events \
            "${db}" 2>>"${LOG_FILE}" | gzip -9 > "${dump_file}"
        local dump_rc=${PIPESTATUS[0]}
        set -e

        if (( dump_rc == 0 )); then
            chmod 600 "${dump_file}"
            ok=$((ok + 1))
        else
            error "Falha no dump do banco: ${db} (rc=${dump_rc})"
            rm -f "${dump_file}"
            fail=$((fail + 1))
        fi
    done <<< "${db_list}"

    info "Dump finalizado: ${ok} banco(s) OK, ${fail} falha(s)."

    if (( fail > 0 )); then
        warn "Alguns bancos falharam no dump. Backup do ${BACKUP_SOURCE} continuará, mas revise o log."
    fi
}

# ---------------------------------------------------------------------------
# ARQUIVO DE EXCLUSÕES
# ---------------------------------------------------------------------------
# NOTA: mantidos os excludes originais. Ciente de que *.log e .git são
# excluídos do restic — se precisar do histórico git ou de logs para auditoria
# ao restaurar uma app, remova as linhas correspondentes.

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

# Arquivos de processo/sistema
*.sock
*.pid
swap
swapfile

# Lixeiras locais
.Trash
.trash

# Backups gerados por plugins WordPress
*/wp-content/ai1wm-backups/*
*/wp-content/updraft/*
*/wp-content/backups-dup-lite/*
*/wp-content/backup-db/*
*/wp-content/wpvividbackups/*
EXCLUDES
}

# ---------------------------------------------------------------------------
# BACKUP DO /HOME
# ---------------------------------------------------------------------------

run_backup() {
    info "Iniciando backup restic de ${BACKUP_SOURCE}"
    info "Repositório: ${RESTIC_REPOSITORY}"

    local restic_flags=(
        backup
        "${BACKUP_SOURCE}"
        --exclude-file="${EXCLUDE_FILE}"
        --tag "host=$(hostname -s)"
        --tag "runcloud"
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
}

# ---------------------------------------------------------------------------
# BACKUP SEMANAL — .tar.gz por aplicação (dia configurável ou FORCE_ARCHIVE)
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

    local today base_s3_path
    today="$(date '+%Y-%m-%d')"
    base_s3_path="s3://${S3_BUCKET}/${ARCHIVE_S3_PREFIX}/${S3_PREFIX}/${today}"

    info "Iniciando backup compactado semanal por aplicação."
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

    # Aplicações RunCloud: /home/usuario/webapps/app
    local app_count=0 fail_count=0
    while IFS= read -r app_path; do
        [[ -z "${app_path}" ]] && continue
        [[ ! -d "${app_path}" ]] && continue

        local app_name owner_name s3_file
        app_name="$(basename "${app_path}")"
        owner_name="$(basename "$(dirname "$(dirname "${app_path}")")")"  # /home/<owner>/webapps/<app>
        s3_file="${base_s3_path}/${owner_name}-${app_name}.tar.gz"

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
            fail_count=$((fail_count + 1))
        fi
    done < <(find "${BACKUP_SOURCE}" -mindepth 3 -maxdepth 3 -type d -path "${BACKUP_SOURCE}/*/webapps/*" | sort)

    info "Backup compactado semanal finalizado: ${app_count} aplicação(ões) OK, ${fail_count} falha(s)."

    # NOTA: a retenção/expiração dos .tar.gz é feita por uma S3 Lifecycle Rule
    # no próprio bucket (prefixo Snapshots/, expira após N dias) — configurada
    # uma única vez pelo instalar_backup.sh. Por isso o script NÃO apaga os
    # baixáveis aqui. A variável ARCHIVE_KEEP_WEEKS fica só como referência da
    # janela desejada (o valor efetivo é o "Days" da regra de lifecycle).
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

        restic check --read-data-subset="${CHECK_DATA_SUBSET}" \
            || warn "restic check encontrou problemas. Rode 'restic check --read-data' completo se necessário."

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
# no repositório nem em /home.

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

    # Valida que ao menos um dump foi restaurado e é um gzip íntegro.
    local restored_dump
    restored_dump="$(find "${RESTORE_TEST_DIR}" -type f -name "*.sql.gz" | head -1 || true)"

    if [[ -z "${restored_dump}" ]]; then
        warn "Nenhum dump .sql.gz na amostra restaurada (talvez não haja bancos). Validando arquivos genéricos."
        local any_file
        any_file="$(find "${RESTORE_TEST_DIR}" -type f | head -1 || true)"
        [[ -z "${any_file}" ]] && die "Restore não materializou nenhum arquivo. FALHA no teste."
        info "Arquivo restaurado com sucesso: ${any_file}"
    else
        info "Validando integridade do dump restaurado: ${restored_dump}"
        if gzip -t "${restored_dump}" 2>>"${LOG_FILE}"; then
            info "Dump restaurado e íntegro (gzip -t OK): ${restored_dump}"
        else
            die "Dump restaurado está CORROMPIDO: ${restored_dump}. FALHA no teste."
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
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
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
    build_mysql_defaults_file

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
