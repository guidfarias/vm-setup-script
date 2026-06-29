#!/bin/bash
# =============================================================================
# restic-backup.sh — Backup completo de /home para S3
# RunCloud / CIPNET
#
# O que este script faz:
#   1. Carrega variáveis de /etc/restic/env
#   2. Valida pré-requisitos
#   3. Faz dump de todos os bancos MySQL em /home/backups/db
#   4. Faz backup incremental do /home completo com restic
#   5. Gera .tar.gz por aplicação e envia ao S3 (sextas ou FORCE_ARCHIVE=true)
#   6. Aplica retenção
#   7. Executa check semanal de integridade
#
# Uso:
#   bash restic-backup.sh
#   bash restic-backup.sh --dry-run
#   bash restic-backup.sh --check
#   FORCE_ARCHIVE=true bash restic-backup.sh
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

DB_DUMP_DIR="${DB_DUMP_DIR:-/home/backups/db}"

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-2}"
KEEP_MONTHLY="${KEEP_MONTHLY:-2}"

CHECK_DAY="${CHECK_DAY:-0}"
CHECK_DATA_SUBSET="${CHECK_DATA_SUBSET:-5G}"

LOG_FILE="${LOG_FILE:-/var/log/restic-backup.log}"
LOG_MAX_LINES=5000

DRY_RUN=false
FORCE_CHECK=false

ENABLE_WEEKLY_ARCHIVES="${ENABLE_WEEKLY_ARCHIVES:-true}"
ARCHIVE_DAY="${ARCHIVE_DAY:-5}"
ARCHIVE_S3_PREFIX="${ARCHIVE_S3_PREFIX:-Snapshots}"
ARCHIVE_KEEP_WEEKS="${ARCHIVE_KEEP_WEEKS:-4}"

# ---------------------------------------------------------------------------
# FUNÇÕES DE LOG
# ---------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${ts} [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }
die()   { error "$@"; exit 1; }

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
# ARGUMENTOS
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true ;;
        --check)   FORCE_CHECK=true ;;
        --help|-h)
            echo "Uso:"
            echo "  bash restic-backup.sh"
            echo "  bash restic-backup.sh --dry-run"
            echo "  bash restic-backup.sh --check"
            echo "  FORCE_ARCHIVE=true bash restic-backup.sh"
            exit 0
            ;;
        *) die "Argumento desconhecido: ${arg}" ;;
    esac
done

# ---------------------------------------------------------------------------
# CARREGA VARIÁVEIS EXTERNAS
# ---------------------------------------------------------------------------

if [[ -f "${RESTIC_ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${RESTIC_ENV_FILE}"
    info "Variáveis carregadas de ${RESTIC_ENV_FILE}"
else
    warn "Arquivo ${RESTIC_ENV_FILE} não encontrado. Usando variá[118;1:3uveis do ambiente."
fi

# ---------------------------------------------------------------------------
# VALIDAÇÕES
# ---------------------------------------------------------------------------

validate_env() {
    local errors=0

    command -v restic &>/dev/null || {
        error "restic não encontrado. Instale: ver documentação."
        ((++errors))
    }

    command -v mysqldump &>/dev/null || {
        error "mysqldump não encontrado. Instale com: apt install mysql-client -y"
        ((++errors))
    }

    command -v mysql &>/dev/null || {
        error "mysql client não encontrado. Instale com: apt install mysql-client -y"
        ((++errors))
    }

    command -v gzip &>/dev/null || {
        error "gzip não encontrado."
        ((++errors))
    }

    [[ -z "${AWS_ACCESS_KEY_ID}" ]] && {
        error "AWS_ACCESS_KEY_ID não definido."
        ((++errors))
    }

    [[ -z "${AWS_SECRET_ACCESS_KEY}" ]] && {
        error "AWS_SECRET_ACCESS_KEY não definido."
        ((++errors))
    }

    [[ -z "${RESTIC_PASSWORD}" ]] && {
        error "RESTIC_PASSWORD não definido."
        ((++errors))
    }

    [[ -z "${S3_BUCKET}" ]] && {
        error "S3_BUCKET não definido."
        ((++errors))
    }

    (( errors == 0 )) || die "${errors} erro(s) de configuração encontrados. Abortando."
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
# INICIALIZA REPOSITÓRIO (se necessário)
# ---------------------------------------------------------------------------

init_repo_if_needed() {
    if restic snapshots &>/dev/null; then
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

dump_databases() {
    info "Iniciando dump dos bancos MySQL em ${DB_DUMP_DIR}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando dump de bancos."
        return 0
    fi

    local mysql_pass_arg=""
    if [[ -n "${MYSQL_PASSWORD}" ]]; then
        mysql_pass_arg="--password=${MYSQL_PASSWORD}"
    fi

    # Valida conexão com MySQL ANTES de apagar dumps antigos
    info "Testando conexão com MySQL..."
    if ! mysql \
        --user="${MYSQL_USER}" \
        ${mysql_pass_arg} \
        --host="${MYSQL_HOST}" \
        --silent \
        -e "SELECT 1;" &>/dev/null; then
        die "Falha ao conectar no MySQL. Dumps antigos preservados."
    fi
    info "Conexão com MySQL OK."

    # Só limpa os dumps antigos após confirmar que o MySQL está acessível
    mkdir -p "${DB_DUMP_DIR}"
    chmod 700 "${DB_DUMP_DIR}"
    info "Limpando dumps antigos em ${DB_DUMP_DIR}"
    find "${DB_DUMP_DIR}" -type f -name "*.sql.gz" -delete

    local db_list
    db_list=$(mysql \
        --user="${MYSQL_USER}" \
        ${mysql_pass_arg} \
        --host="${MYSQL_HOST}" \
        --skip-column-names \
        --silent \
        -e "SHOW DATABASES;" \
        2>>"${LOG_FILE}" \
        | grep -Ev "^(information_schema|performance_schema|sys|mysql)$"
    ) || die "Falha ao listar bancos de dados."

    if [[ -z "${db_list}" ]]; then
        warn "Nenhum banco de usuário encontrado."
        return 0
    fi

    local ok=0
    local fail=0

    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue

        local dump_file="${DB_DUMP_DIR}/${db}.sql.gz"

        info "Dumping banco: ${db}"

        if mysqldump \
            --user="${MYSQL_USER}" \
            ${mysql_pass_arg} \
            --host="${MYSQL_HOST}" \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --events \
            "${db}" \
            2>>"${LOG_FILE}" \
            | gzip -9 > "${dump_file}"; then

            chmod 600 "${dump_file}"
            ((++ok))
        else
            error "Falha no dump do banco: ${db}"
            rm -f "${dump_file}"
            ((++fail))
        fi
    done <<< "${db_list}"

    info "Dump finalizado: ${ok} banco(s) OK, ${fail} falha(s)."

    if (( fail > 0 )); then
        warn "Alguns bancos falharam no dump. Backup do /home continuará, mas revise o log."
    fi
}

# ---------------------------------------------------------------------------
# ARQUIVO DE EXCLUSÕES (criado após source do env)
# ---------------------------------------------------------------------------

build_exclude_file() {
    EXCLUDE_FILE="$(mktemp /tmp/restic-excludes.XXXXXX)"
    trap 'rm -f "${EXCLUDE_FILE}"' EXIT

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
    info "Iniciando backup restic de /home"
    info "Repositório: ${RESTIC_REPOSITORY}"

    local restic_flags=(
        backup
        /home
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
# BACKUP SEMANAL — .tar.gz por aplicação (sextas ou FORCE_ARCHIVE=true)
# ---------------------------------------------------------------------------

run_weekly_app_archives() {
    if [[ "${ENABLE_WEEKLY_ARCHIVES}" != "true" ]]; then
        info "Arquivos compactados semanais desativados (ENABLE_WEEKLY_ARCHIVES != true)."
        return 0
    fi

    local today_dow
    today_dow="$(date +%w)"

    if [[ "${today_dow}" != "${ARCHIVE_DAY}" ]] && [[ "${FORCE_ARCHIVE:-false}" != "true" ]]; then
        info "Backup compactado semanal pulado. Configurado para rodar no dia ${ARCHIVE_DAY} (hoje: ${today_dow})."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando geração dos compactados semanais."
        return 0
    fi

    command -v aws &>/dev/null || {
        warn "aws cli não encontrado. Instale com: apt install awscli -y"
        return 0
    }

    local today
    today="$(date '+%Y-%m-%d')"
    local base_s3_path="s3://${S3_BUCKET}/${ARCHIVE_S3_PREFIX}/${S3_PREFIX}/${today}"

    info "Iniciando backup compactado semanal por aplicação."
    info "Destino S3: ${base_s3_path}"

    # Dumps dos bancos
    if [[ -d "${DB_DUMP_DIR}" ]]; then
        info "Gerando arquivo compactado dos dumps dos bancos."
        tar -czf - -C "$(dirname "${DB_DUMP_DIR}")" "$(basename "${DB_DUMP_DIR}")" \
            2>>"${LOG_FILE}" \
            | aws s3 cp - "${base_s3_path}/databases-all.tar.gz" \
                --region "${AWS_DEFAULT_REGION}" \
                >>"${LOG_FILE}" 2>&1 \
            || warn "Falha ao enviar databases-all.tar.gz para o S3."
    else
        warn "Diretório de dumps não encontrado: ${DB_DUMP_DIR}"
    fi

    # Aplicações RunCloud: /home/usuario/webapps/app
    local app_count=0
    local fail_count=0

    while IFS= read -r app_path; do
        [[ -z "${app_path}" ]] && continue
        [[ ! -d "${app_path}" ]] && continue

        local app_name owner_name s3_file
        app_name="$(basename "${app_path}")"
        owner_name="$(echo "${app_path}" | awk -F/ '{print $3}')"
        s3_file="${base_s3_path}/${owner_name}-${app_name}.tar.gz"

        info "Compactando: ${app_path} → ${s3_file}"

        if tar -czf - \
            --exclude="wp-content/cache" \
            --exclude="wp-content/upgrade" \
            --exclude="wp-content/ai1wm-backups" \
            --exclude="wp-content/updraft" \
            --exclude="wp-content/backups-dup-lite" \
            --exclude="wp-content/wpvividbackups" \
            --exclude="node_modules" \
            --exclude=".git" \
            -C "$(dirname "${app_path}")" "$(basename "${app_path}")" \
            2>>"${LOG_FILE}" \
            | aws s3 cp - "${s3_file}" \
                --region "${AWS_DEFAULT_REGION}" \
                >>"${LOG_FILE}" 2>&1; then
            ((++app_count))
        else
            warn "Falha ao compactar/enviar: ${app_path}"
            ((++fail_count))
        fi

    done < <(find /home -mindepth 3 -maxdepth 3 -type d -path "/home/*/webapps/*" | sort)

    info "Backup compactado semanal finalizado: ${app_count} aplicação(ões) OK, ${fail_count} falha(s)."
}

# ---------------------------------------------------------------------------
# RETENÇÃO
# ---------------------------------------------------------------------------

run_forget() {
    info "Aplicando retenção: daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}"

    local forget_flags=(
        forget
        --keep-daily  "${KEEP_DAILY}"
        --keep-weekly "${KEEP_WEEKLY}"
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
            || warn "restic check encontrou problemas. Rode check completo manualmente se necessário."

        info "Check finalizado."
    else
        info "Check pulado. Configurado para o dia da semana: ${CHECK_DAY} (hoje: ${today_dow})"
    fi
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
    rotate_log

    info "════════════════════════════════════════════"
    info "Backup iniciado | host: $(hostname -s) | data: $(date '+%Y-%m-%d %H:%M:%S')"
    info "════════════════════════════════════════════"

    [[ "${DRY_RUN}" == "true" ]] && warn "Modo DRY-RUN ativo."

    validate_env
    export_restic_env
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
}

main
